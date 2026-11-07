import AppKit
import AVFoundation
import Foundation
import ST2110Core
import ST2110Kit

/// Steuert das Senden: Quelle (Testbild, Datei, Kamera), Format, Adressen,
/// NMOS-Ankündigung und die Verbindung zu einem Empfänger im Netz (IS-05).
@MainActor
@Observable
final class SenderController {
    enum Source: Hashable {
        case bars
        case syncTest
        case file(URL)
        case camera(String?)
    }

    enum Format: String, CaseIterable, Identifiable {
        case p1080_25 = "1080p25", p1080_50 = "1080p50", p1080_2997 = "1080p29.97", p1080_5994 = "1080p59.94"
        case p720_50 = "720p50", p720_5994 = "720p59.94"
        var id: String { rawValue }
        var size: (Int, Int) { rawValue.hasPrefix("1080") ? (1920, 1080) : (1280, 720) }
        var rate: (Int, Int) {
            switch self {
            case .p1080_25: return (25, 1)
            case .p1080_50, .p720_50: return (50, 1)
            case .p1080_2997: return (30000, 1001)
            case .p1080_5994, .p720_5994: return (60000, 1001)
            }
        }
        /// ungefähre Datenrate (Gbit/s)
        var gbps: Double {
            let (w, h) = size
            return Double(w * h) * 2.5 * 8 * Double(rate.0) / Double(rate.1) / 1e9 * 1.03
        }
    }

    var source: Source = .bars
    var format: Format = .p1080_25
    var audioChannels = 2
    var ptime125 = false
    var videoAddress = ""
    var audioAddress = ""
    var port = 5004
    var audioPort: Int?           // nil = wie Video (Multicast); bei Unicast nötig
    var usePTP = true
    var announceNMOS = true
    var label = "2110 Viewer"
    var microphoneID: String?

    private(set) var isSending = false
    private(set) var isStarting = false
    private(set) var stats: st_sender_stats?
    private(set) var videoSDP: String?
    private(set) var audioSDP: String?
    private(set) var interface: InterfaceSnapshot?
    private(set) var message: String?
    private(set) var nmosPort: Int?
    private(set) var connectedDestination: String?
    private(set) var log: [String] = []

    var interfacesProvider: (() -> [InterfaceSnapshot])?
    var settingsProvider: (() -> AppSettings)?

    private var sender: CoreSender?
    private var feeder: MediaFeeder?
    private let node = NMOSNodeServer()
    private var ids: NMOSNodeResources.Identity
    private var timer: Timer?

    init() {
        if let d = UserDefaults.standard.data(forKey: "NMOSIdentity"),
           let i = try? JSONDecoder().decode(NMOSNodeResources.Identity.self, from: d) {
            ids = i
        } else {
            ids = NMOSNodeResources.Identity.make()
            if let d = try? JSONEncoder().encode(ids) { UserDefaults.standard.set(d, forKey: "NMOSIdentity") }
        }
        label = Host.current().localizedName.map { "2110 Viewer (\($0))" } ?? "2110 Viewer"
        node.onMasterEnable = { [weak self] en in
            Task { @MainActor in
                guard let self else { return }
                self.addLog(en ? "NMOS-Controller hat den Sender aktiviert." : "NMOS-Controller hat den Sender deaktiviert.")
                if !en { self.stop() }
            }
        }
        node.onStatus = { [weak self] s in Task { @MainActor in self?.addLog(s) } }
    }

    var sourceTitle: String {
        switch source {
        case .bars: return "Testbild (Farbbalken, 1 kHz)"
        case .syncTest: return "Lippensynchron-Test (Blitz und Piep)"
        case .file(let u): return u.lastPathComponent
        case .camera(let id): return id.flatMap { AVCaptureDevice(uniqueID: $0)?.localizedName } ?? "Kamera"
        }
    }

    /// Schlägt Multicast-Adressen im eingestellten Bereich vor, abgeleitet aus der
    /// eigenen IP-Adresse (damit mehrere Macs nicht dieselbe Gruppe verwenden).
    func suggestAddresses(range: String, interface: InterfaceSnapshot?) {
        let r = AddressRange.parseList(range)?.first ?? AddressRange.parse("239.0.0.0/8")!
        let host = interface?.ipv4.flatMap(IPv4.init)?.value ?? 0x0A000001
        let span = max(1, UInt32(r.count) / 4)
        let base = r.first.value &+ ((host & 0xFFFF) % span) * 4
        videoAddress = IPv4(base &+ 1).description
        audioAddress = IPv4(base &+ 2).description
    }

    func start(destination: DiscoveredDestination? = nil, client: NMOSClient? = nil) async {
        guard !isSending, !isStarting else { return }
        isStarting = true
        message = nil
        defer { isStarting = false }
        let settings = settingsProvider?() ?? AppSettings()
        let list = interfacesProvider?() ?? []
        let iface: InterfaceSnapshot? = !settings.interfaceName.isEmpty
            ? list.first(where: { $0.name == settings.interfaceName })
            : InterfaceChoice.preferred(list, senderAddresses: [])
        interface = iface
        if videoAddress.isEmpty || audioAddress.isEmpty { suggestAddresses(range: settings.multicastRange, interface: iface) }
        for (a, n) in [(videoAddress, "Video"), (audioAddress, "Audio")] {
            guard let ip = IPv4(a) else { message = "\(n): „\(a)“ ist keine gültige IPv4-Adresse."; return }
            if ip.isMulticast, let rs = AddressRange.parseList(settings.multicastRange), !rs.isEmpty, !rs.contains(where: { $0.contains(ip) }) {
                message = "\(n): \(a) liegt außerhalb des eingestellten Multicast-Bereichs (\(settings.multicastRange))."
                return
            }
        }
        if case .camera = source {
            guard await CaptureFeeder.authorize(.video) else { message = FeederError.cameraDenied.localizedDescription; return }
            if audioChannels > 0 { _ = await CaptureFeeder.authorize(.audio) }
        }

        var c = st_sender_config()
        if let i = iface {
            setCString(&c.iface_name, i.name)
            setCString(&c.iface_addr, i.ipv4 ?? "")
        }
        setCString(&c.session_name, label)
        c.ttl = 16
        c.has_video = 1
        setCString(&c.video_addr, videoAddress)
        c.video_port = Int32(port)
        let (w, h) = format.size
        let (fn, fd) = format.rate
        c.width = Int32(w); c.height = Int32(h); c.fps_num = Int32(fn); c.fps_den = Int32(fd)
        c.has_audio = audioChannels > 0 ? 1 : 0
        setCString(&c.audio_addr, audioAddress)
        c.audio_port = Int32(audioPort ?? port)
        c.audio_channels = Int32(max(1, audioChannels))
        c.audio_ptime_us = ptime125 ? 125 : 1000
        c.use_ptp = usePTP ? 1 : 0
        c.ptp_domain = Int32(settings.ptpDomain >= 0 ? settings.ptpDomain : 127)
        c.pattern = source == .syncTest ? ST_PATTERN_SYNC : ST_PATTERN_BARS

        // Start (PTP-Wartezeit bis 4 s) abseits des Hauptthreads
        let cfg = c
        let result: (CoreSender?, String?) = await Task.detached(priority: .userInitiated) {
            var e = ""
            guard let s = CoreSender(config: cfg, error: &e) else { return (nil, e) }
            if let err = s.start() { return (nil, err) }
            return (s, nil)
        }.value
        guard let s = result.0 else {
            message = result.1 ?? "Sender konnte nicht starten."
            return
        }
        sender = s
        isSending = true
        videoSDP = s.sdp(video: true)
        audioSDP = c.has_audio != 0 ? s.sdp(video: false) : nil
        var line: String = "Sende " + format.rawValue + " an " + videoAddress + ":" + String(port)
        if c.has_audio != 0 {
            let ap: Int = Int(audioPort ?? port)
            line += " und " + String(audioChannels) + " Kanäle an " + audioAddress + ":" + String(ap)
        }
        let ifName: String = iface?.displayName ?? "Standardschnittstelle"
        addLog(line + " über " + ifName + ".")

        // Quelle
        switch source {
        case .file(let url):
            let f = FileFeeder(url: url)
            do { try f.start(into: s); feeder = f } catch { message = error.localizedDescription }
        case .camera(let id):
            let f = CaptureFeeder(cameraID: id, microphoneID: microphoneID)
            do {
                try f.start(into: s)
                feeder = f
                if let w = f.warning { message = w }
            } catch { message = error.localizedDescription }
        default:
            break
        }

        if announceNMOS { publishNMOS(settings: settings) }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        if let destination, let client { await connect(destination, client: client) }
    }

    func stop() {
        feeder?.stop()
        feeder = nil
        let s = sender
        sender = nil
        Task.detached { s?.stop() }
        node.stop()
        nmosPort = nil
        timer?.invalidate()
        timer = nil
        if isSending { addLog("Senden beendet.") }
        isSending = false
        stats = nil
    }

    private func tick() {
        stats = sender?.stats()
        // Nach PTP-Lock stehen Grandmaster-ID und neue SDP bereit
        if let s = sender, let v = s.sdp(video: true), v != videoSDP {
            videoSDP = v
            audioSDP = audioChannels > 0 ? s.sdp(video: false) : nil
            if announceNMOS { refreshNMOS() }
        }
    }

    private func resources() -> NMOSNodeResources {
        let (w, h) = format.size
        let (fn, fd) = format.rate
        return NMOSNodeResources(ids: ids, label: label, hostname: ProcessInfo.processInfo.hostName,
                                 hostIP: interface?.ipv4 ?? "127.0.0.1", port: nmosPort ?? 0,
                                 interfaceName: interface?.name ?? "en0",
                                 video: .init(width: w, height: h, fpsNum: fn, fpsDen: fd, destination: videoAddress, port: port),
                                 audio: audioChannels > 0 ? .init(channels: audioChannels, destination: audioAddress, port: audioPort ?? port) : nil,
                                 active: isSending)
    }

    private func publishNMOS(settings: AppSettings) {
        node.start(name: label) { [weak self] p in
            Task { @MainActor in
                guard let self, let p else { return }
                self.nmosPort = p
                self.refreshNMOS()
                self.addLog("Als NMOS-Knoten angekündigt (mDNS, Port \(p)).")
                let reg = settings.registryURL.trimmingCharacters(in: .whitespaces)
                if !reg.isEmpty {
                    var s = reg.contains("://") ? reg : "http://\(reg)"
                    if !s.contains("/x-nmos/") { s += "/x-nmos/registration/v1.3/" }
                    if let u = URL(string: s) { self.node.register(registry: u); self.addLog("Bei Registry \(reg) angemeldet.") }
                }
            }
        }
    }

    private func refreshNMOS() {
        node.update(resources: resources(), sdpVideo: videoSDP, sdpAudio: audioSDP)
    }

    /// Verbindet einen NMOS-Empfänger (z. B. SDI-Ausgang eines 3x3G) per IS-05.
    func connect(_ d: DiscoveredDestination, client: NMOSClient) async {
        guard let api = d.connectionAPI else {
            message = "Das Gerät meldet keine IS-05-Schnittstelle. Bitte am Gerät (LCD-Menü bzw. Converters Setup) den 2110-Viewer-Sender als Quelle wählen."
            return
        }
        do {
            if let v = d.video { try await client.connectReceiver(connectionAPI: api, receiverID: v.id, senderID: ids.videoSender, sdp: videoSDP, enable: true) }
            if let a = d.audio.first, audioSDP != nil {
                try await client.connectReceiver(connectionAPI: api, receiverID: a.id, senderID: ids.audioSender, sdp: audioSDP, enable: true)
            }
            connectedDestination = "\(d.deviceLabel) – \(d.title)"
            addLog("Verbunden mit \(d.deviceLabel) – \(d.title) (IS-05).")
        } catch {
            message = "Verbinden mit \(d.title) fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    func disconnect(_ d: DiscoveredDestination, client: NMOSClient) async {
        guard let api = d.connectionAPI else { return }
        for r in ([d.video] + d.audio.map { Optional($0) }).compactMap({ $0 }) {
            try? await client.connectReceiver(connectionAPI: api, receiverID: r.id, senderID: nil, sdp: nil, enable: false)
        }
        connectedDestination = nil
        addLog("Verbindung zu \(d.title) getrennt.")
    }

    func copySDP() {
        let text = [videoSDP, audioSDP].compactMap { $0 }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func saveSDP() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Hier speichern"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        try? videoSDP?.write(to: dir.appendingPathComponent("essenz-video.sdp"), atomically: true, encoding: .utf8)
        try? audioSDP?.write(to: dir.appendingPathComponent("essenz-audio.sdp"), atomically: true, encoding: .utf8)
    }

    private func addLog(_ s: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        log.append("\(f.string(from: Date()))  \(s)")
        if log.count > 100 { log.removeFirst() }
    }
}
