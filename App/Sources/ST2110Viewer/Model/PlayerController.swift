import AppKit
import Foundation
import ST2110Core
import ST2110Kit
import SwiftUI

/// Steuert einen Empfänger: Start/Stopp, Lautstärke, Abhörauswahl,
/// automatische Wiederverbindung, Diagnose. Die Oberfläche bleibt bedienbar,
/// weil alle blockierenden Aufrufe (Start mit PTP-Wartezeit, Stopp) auf einer
/// eigenen Warteschlange laufen.
@MainActor
@Observable
final class PlayerController {
    struct LogEntry: Identifiable {
        let id = UUID()
        let date: Date
        let level: Hint.Severity
        let text: String
    }

    enum Phase: Equatable {
        case idle
        case starting
        case running
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var current: SavedSource?
    private(set) var video: SDPMedia?
    private(set) var audio: SDPMedia?
    private(set) var isDemo = false
    private(set) var stats: st_stats?
    private(set) var levels: [Float] = []
    private(set) var coreState: st_state = ST_STATE_STOPPED
    private(set) var stateSince = Date()
    private(set) var log: [LogEntry] = []
    private(set) var formatProblem: String?
    private(set) var mediaWarnings: [String] = []
    private(set) var ptpMessage: String?
    private(set) var reconnects = 0
    private(set) var interface: InterfaceSnapshot?
    private(set) var effectiveSync: AppSettings.SyncChoice = .automatic
    var nmosActive: IS05SenderParams?
    var nmosSenderEnabled: Bool? { nmosActive?.master_enable }

    var monitorLeft = 0 { didSet { applyMonitor() } }
    var monitorRight = 1 { didSet { applyMonitor() } }

    let sink = VideoFrameSink()
    let renderer: VideoRenderer

    /// Liefert für NMOS-Quellen eine aktualisierte Quelle (neue SDP), sonst nil.
    var refreshSource: ((SavedSource) async -> SavedSource?)?
    var interfacesProvider: (() -> [InterfaceSnapshot])?
    var audioDeviceResolver: ((String) -> Int)?

    private var receiver: CoreReceiver?
    private let queue = DispatchQueue(label: "st2110.receiver", qos: .userInitiated)
    private var timer: Timer?
    private var tick = 0
    private var wantPlaying = false
    private var settings = AppSettings()
    private var nextRetry: Date?
    private var retryDelay: Double = 2
    private var lastNMOSPoll = Date.distantPast
    private var lastInterfaceIP: String?
    private var generation = 0

    init() {
        renderer = VideoRenderer(sink: sink)
        timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onTick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    var channelCount: Int { isDemo ? 16 : (audio?.channels ?? 0) }
    var isActive: Bool { wantPlaying }

    // MARK: Start/Stopp

    func playDemo(settings: AppSettings) {
        var src = SavedSource(name: "Demo: Testbild und Testton", origin: .manual)
        src.id = UUID(uuidString: "00000000-0000-0000-0000-00000000DE30")!
        start(source: src, settings: settings, demo: true)
    }

    func play(_ source: SavedSource, settings: AppSettings) {
        start(source: source, settings: settings, demo: false)
    }

    func togglePlay(settings: AppSettings) {
        if wantPlaying { stop() } else if let c = current { start(source: c, settings: settings, demo: isDemo) }
    }

    func stop() {
        wantPlaying = false
        generation += 1
        let r = receiver
        receiver = nil
        queue.async { r?.stop() }
        sink.clear()
        phase = .idle
        stats = nil
        levels = []
        coreState = ST_STATE_STOPPED
        stateSince = Date()
        nextRetry = nil
    }

    private func start(source: SavedSource, settings: AppSettings, demo: Bool) {
        let previous = receiver
        receiver = nil
        generation += 1
        let gen = generation
        self.settings = settings
        current = source
        isDemo = demo
        wantPlaying = true
        formatProblem = nil
        ptpMessage = nil
        mediaWarnings = []
        phase = .starting
        coreState = ST_STATE_STARTING
        stateSince = Date()
        sink.clear()

        var cfg = st_receiver_config()
        if demo {
            cfg.demo = 1
            cfg.demo_fps = 25
            cfg.demo_channels = 16
            video = nil
            audio = nil
            if monitorRight >= 16 || monitorLeft >= 16 { monitorLeft = 0; monitorRight = 1 }
        } else {
            let (v, a, warnings, error) = Self.selectMedia(source)
            video = v
            audio = a
            mediaWarnings = warnings
            if let error {
                phase = .failed(error)
                wantPlaying = false
                coreState = ST_STATE_ERROR
                addLog(.error, error)
                queue.async { previous?.stop() }
                return
            }
            if let v { cfg.has_video = 1; cfg.video = v.raw }
            if let a { cfg.has_audio = 1; cfg.audio = a.raw }
            if let l = source.monitorLeft { monitorLeft = l }
            if let r = source.monitorRight { monitorRight = r }
            let ch = a?.channels ?? 0
            if monitorLeft >= ch { monitorLeft = 0 }
            if monitorRight >= ch { monitorRight = ch >= 2 ? 1 : -1 }

            // Netzwerkschnittstelle
            let list = interfacesProvider?() ?? []
            let senders = [v?.senderAddress, a?.senderAddress].compactMap { $0 }
            let chosen: InterfaceSnapshot?
            if !settings.interfaceName.isEmpty, let i = list.first(where: { $0.name == settings.interfaceName }) {
                chosen = i
            } else if let pref = source.interfaceName, let i = list.first(where: { $0.name == pref }) {
                chosen = i
            } else {
                chosen = InterfaceChoice.preferred(list, senderAddresses: senders)
            }
            interface = chosen
            lastInterfaceIP = chosen?.ipv4
            if let i = chosen {
                setCString(&cfg.iface_name, i.name)
                setCString(&cfg.iface_addr, i.ipv4 ?? "")
            }
            cfg.use_source_filter = settings.useSourceFilter ? 1 : 0
            cfg.socket_buffer_bytes = Int32(settings.socketBufferMB * 1024 * 1024)
            switch settings.sync {
            case .automatic: cfg.sync_mode = ST_SYNC_PTP
            case .rtpAligned: cfg.sync_mode = ST_SYNC_RTP_ALIGNED
            case .preview: cfg.sync_mode = ST_SYNC_PREVIEW
            }
            effectiveSync = settings.sync
            cfg.ptp_domain = Int32(settings.ptpDomain)
            cfg.ptp_timeout_ms = Int32(max(1, settings.ptpTimeoutSeconds) * 1000)
            cfg.latency_ms = Int32(settings.latencyMs)
            cfg.auto_latency = settings.autoLatency ? 1 : 0
        }
        cfg.audio_device_id = Int32(audioDeviceResolver?(settings.audioDeviceUID) ?? 0)

        let rec = CoreReceiver(frameSink: sink) { [weak self] ev, code, msg in
            Task { @MainActor in self?.handleEvent(ev, code, msg, gen: gen) }
        }
        let volume = settings.volume, muted = settings.muted, delay = settings.audioDelayMs
        let l = monitorLeft, r = monitorRight
        addLog(.info, demo ? "Demo-Modus gestartet." : "Starte „\(source.name)“ über \(interface.map { "\($0.displayName) (\($0.name))" } ?? "Standardschnittstelle").")
        queue.async { [weak self] in
            previous?.stop()
            let err = rec.start(config: cfg)
            if err == nil {
                rec.setVolume(volume)
                rec.setMute(muted)
                rec.setMonitor(left: l, right: r)
                rec.setAudioDelay(ms: delay)
            } else {
                rec.stop()
            }
            Task { @MainActor in
                guard let self, self.generation == gen else { rec.stop(); return }
                if let err {
                    self.phase = .failed(err)
                    self.coreState = ST_STATE_ERROR
                    self.addLog(.error, err)
                    self.scheduleRetry()
                } else {
                    self.receiver = rec
                    self.phase = .running
                }
            }
        }
    }

    /// Wählt Video- und Audioabschnitt aus den SDPs und prüft die Unterstützung.
    static func selectMedia(_ s: SavedSource) -> (SDPMedia?, SDPMedia?, [String], String?) {
        var warnings: [String] = []
        var errors: [String] = []
        var videos: [SDPMedia] = []
        var audios: [SDPMedia] = []
        for text in [s.videoSDP, s.audioSDP].compactMap({ $0 }) where !text.isEmpty {
            let (m, err) = SDPMedia.parse(text)
            if let err { errors.append(err) }
            for x in m {
                if x.kind == .video { videos.append(x) } else if x.kind == .audio { audios.append(x) }
            }
        }
        var v = videos.first
        var a: SDPMedia? = nil
        if let idx = s.audioMediaIndex, idx < audios.count { a = audios[idx] } else { a = audios.first }
        if let vv = v {
            let (sup, msg) = vv.check
            if sup == .unsupported { errors.append("Video: \(msg)"); v = nil } else if sup == .warning { warnings.append("Video: \(msg)") }
        }
        if let aa = a {
            let (sup, msg) = aa.check
            if sup == .unsupported { errors.append("Audio: \(msg)"); a = nil } else if sup == .warning { warnings.append("Audio: \(msg)") }
        }
        if v == nil && a == nil {
            let e = errors.isEmpty ? "Die Quelle enthält weder einen Video- noch einen Audiostrom, der wiedergegeben werden kann." : errors.joined(separator: "\n")
            return (nil, nil, warnings, e)
        }
        // Teilweise unterstützt: abspielen, Fehler als Warnung anzeigen
        return (v, a, warnings + errors, nil)
    }

    // MARK: Ereignisse

    private func handleEvent(_ ev: st_event, _ code: Int32, _ msg: String, gen: Int) {
        guard gen == generation else { return }
        switch ev {
        case ST_EVENT_STATE:
            let s = st_state(rawValue: UInt32(code))
            if s != coreState {
                coreState = s
                stateSince = Date()
                if s == ST_STATE_RECEIVING {
                    retryDelay = 2
                    nextRetry = nil
                    announce("Empfang läuft")
                } else if s == ST_STATE_STALLED {
                    announce("Signal unterbrochen")
                    addLog(.warning, "Signal unterbrochen.")
                }
            }
        case ST_EVENT_ERROR:
            addLog(.error, msg)
            coreState = ST_STATE_ERROR
            stateSince = Date()
            scheduleRetry()
        case ST_EVENT_WARNING:
            addLog(.warning, msg)
        case ST_EVENT_FORMAT_MISMATCH:
            formatProblem = msg
            addLog(.error, msg)
            announce("Formatproblem: \(msg)")
            if current?.nmos != nil { lastNMOSPoll = .distantPast }
        case ST_EVENT_SENDER_RESTART:
            addLog(.info, msg)
        case ST_EVENT_PTP:
            ptpMessage = msg
            addLog(code == 1 ? .info : .warning, msg)
        default:
            addLog(.info, msg)
        }
    }

    private func scheduleRetry() {
        guard wantPlaying else { return }
        nextRetry = Date().addingTimeInterval(retryDelay)
        addLog(.info, String(format: "Neuer Verbindungsversuch in %.0f s.", retryDelay))
        retryDelay = min(retryDelay * 2, 30)
    }

    private func restart(reason: String) {
        guard let c = current else { return }
        reconnects += 1
        addLog(.info, reason)
        start(source: c, settings: settings, demo: isDemo)
    }

    // MARK: Takt

    private func onTick() {
        tick += 1
        guard let r = receiver else {
            if wantPlaying, let n = nextRetry, Date() >= n {
                nextRetry = nil
                restart(reason: "Neuer Verbindungsversuch …")
            }
            return
        }
        levels = r.levels()
        if tick % 5 == 0 { stats = r.stats() }
        if tick % 20 == 0 { watchdog() }
    }

    private func watchdog() {
        guard wantPlaying, !isDemo else { return }
        let now = Date()
        let inState = now.timeIntervalSince(stateSince)
        if coreState == ST_STATE_ERROR, let n = nextRetry, now >= n {
            nextRetry = nil
            restart(reason: "Neuer Verbindungsversuch nach Fehler …")
            return
        }
        // Lang anhaltende Unterbrechung: Multicast neu beitreten (Switch-/Adapterwechsel)
        if coreState == ST_STATE_STALLED || (coreState == ST_STATE_WAITING && inState > 8) {
            if nextRetry == nil { nextRetry = now.addingTimeInterval(max(5, retryDelay)) }
            if let n = nextRetry, now >= n {
                retryDelay = min(retryDelay * 2, 30)
                nextRetry = nil
                restart(reason: "Neuverbindung (Multicast neu beitreten) …")
                return
            }
        }
        // Netzwerkschnittstelle geändert (Adapter neu gesteckt, neue Adresse)
        if let name = interface?.name, let list = interfacesProvider?() {
            let nowIP = list.first(where: { $0.name == name })?.ipv4
            if nowIP != lastInterfaceIP {
                lastInterfaceIP = nowIP
                if nowIP != nil { restart(reason: "Netzwerkadresse von \(name) hat sich geändert. Verbinde neu …"); return }
            }
        }
        // NMOS: Senderänderungen (neue SDP) übernehmen
        if let c = current, c.nmos != nil, now.timeIntervalSince(lastNMOSPoll) > 10, let refresh = refreshSource {
            lastNMOSPoll = now
            let gen = generation
            Task {
                if let updated = await refresh(c), self.generation == gen, self.wantPlaying {
                    self.addLog(.info, "Der Sender hat seine Parameter geändert (neue SDP über NMOS).")
                    self.current = updated
                    self.restart(reason: "Übernehme neue Senderparameter …")
                }
            }
        }
    }

    // MARK: Mitschnitt

    private(set) var recordingURL: URL?

    /// Zeichnet die empfangenen Pakete als pcapng auf (Software-Zeitstempel).
    func startRecording(seconds: Int) -> URL? {
        guard let r = receiver else { return nil }
        let dir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("2110-Viewer-Mitschnitte", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let name = (current?.name ?? "Mitschnitt").replacingOccurrences(of: "/", with: "-")
        let url = dir.appendingPathComponent("\(name)_\(f.string(from: Date())).pcapng")
        if let e = r.startRecording(path: url.path, seconds: seconds) {
            addLog(.error, e)
            return nil
        }
        recordingURL = url
        addLog(.info, "Mitschnitt läuft (\(seconds) s): \(url.lastPathComponent)")
        return url
    }

    func stopRecording() {
        receiver?.stopRecording()
        if let u = recordingURL { addLog(.info, "Mitschnitt gespeichert: \(u.path)") }
    }

    var isRecording: Bool { (stats?.recording ?? 0) != 0 }

    // MARK: Audio

    func setVolume(_ v: Double) { let r = receiver; queue.async { r?.setVolume(v) } }
    func setMute(_ m: Bool) { let r = receiver; queue.async { r?.setMute(m) } }
    func setAudioDelay(_ ms: Int) { let r = receiver; queue.async { r?.setAudioDelay(ms: ms) } }

    private func applyMonitor() {
        let r = receiver, l = monitorLeft, rr = monitorRight
        queue.async { r?.setMonitor(left: l, right: rr) }
    }

    func selectPair(_ first: Int) {
        let n = channelCount
        guard n > 0 else { return }
        monitorLeft = max(0, min(first, n - 1))
        monitorRight = monitorLeft + 1 < n ? monitorLeft + 1 : -1
    }

    func nextPair(_ delta: Int) {
        let n = channelCount
        guard n > 1 else { return }
        var f = monitorLeft + 2 * delta
        if f < 0 { f = ((n - 1) / 2) * 2 }
        if f >= n { f = 0 }
        selectPair(f)
    }

    // MARK: Hilfen

    func addLog(_ level: Hint.Severity, _ text: String) {
        log.append(LogEntry(date: Date(), level: level, text: text))
        if log.count > 300 { log.removeFirst(log.count - 300) }
    }

    private func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }

    var diagnosisInput: DiagnosisInput {
        var d = DiagnosisInput(state: {
            switch coreState {
            case ST_STATE_STARTING: return .starting
            case ST_STATE_WAITING: return .waiting
            case ST_STATE_RECEIVING: return .receiving
            case ST_STATE_STALLED: return .stalled
            case ST_STATE_ERROR: return .error
            default: return .stopped
            }
        }())
        d.secondsInState = Date().timeIntervalSince(stateSince)
        d.expectsVideo = video != nil
        d.expectsAudio = audio != nil
        if let s = stats {
            d.videoPackets = s.v_packets
            d.audioPackets = s.a_packets
            d.videoLost = s.v_lost
            d.audioLost = s.a_lost
            d.videoRateMbps = s.v_rate_mbps
            d.framesDropped = s.v_frames_dropped
            d.ptpActive = s.sync_active == ST_SYNC_PTP
            d.ptpDomainsSeen = Int(s.ptp_domains_seen)
            d.ptpGrandmasterMatchesSDP = Int(s.ptp_gm_matches_sdp)
            d.socketBufferBytes = Int(s.socket_buffer_bytes)
            d.latencyRaised = s.latency_auto_raised > 0
            d.latencyMs = s.latency_ms
        }
        d.interface = interface
        d.otherInterfaces = interfacesProvider?() ?? []
        d.senderAddress = video?.senderAddress ?? audio?.senderAddress
        d.multicastGroups = [video.map { "\($0.destination):\($0.port)" }, audio.map { "\($0.destination):\($0.port)" }].compactMap { $0 }
        d.ptpRequested = effectiveSync == .automatic && !isDemo
        d.nmosSenderEnabled = nmosSenderEnabled
        return d
    }

    var hints: [Hint] { isDemo ? [] : Diagnosis.hints(diagnosisInput) }

    /// Textbericht für Rückmeldungen (Testplan) – kopierbar.
    func reportText(appVersion: String) -> String {
        var t = "2110 Viewer \(appVersion) – Diagnosebericht \(ISO8601DateFormatter().string(from: Date()))\n"
        t += "macOS \(ProcessInfo.processInfo.operatingSystemVersionString), GStreamer \(GStreamerEnvironment.version)\n"
        t += "Quelle: \(current?.name ?? "-") (\(isDemo ? "Demo" : current?.origin.rawValue ?? "-"))\n"
        if let i = interface { t += "Schnittstelle: \(i.menuTitle)\n" }
        t += "Synchronisation gewünscht: \(effectiveSync.title)\n"
        if let v = video { t += "Video SDP: \(v.summary) an \(v.destination):\(v.port) Quelle \(v.sourceAddress) refclk \(v.refclk)\n" }
        if let a = audio { t += "Audio SDP: \(a.summary) an \(a.destination):\(a.port) Quelle \(a.sourceAddress) refclk \(a.refclk)\n" }
        if let s = stats {
            t += "Zustand: \(String(cString: st_state_name(s.state))), aktiv: \(String(cString: st_sync_mode_name(s.sync_active)))\n"
            t += String(format: "Video: %.0f Mbit/s, %.3f B/s, %d×%d, Pakete %llu, verloren %llu, umsortiert %llu, Bilder %llu, gezeigt %llu, verworfen %llu\n",
                        s.v_rate_mbps, s.v_fps_measured, s.v_width_seen, s.v_height_seen, s.v_packets, s.v_lost, s.v_reordered,
                        s.v_frames, s.v_frames_rendered, s.v_frames_dropped)
            t += String(format: "Audio: Pakete %llu, verloren %llu, Paketzeit %.3f ms, Nutzlast %d Byte, ausgegeben %llu\n",
                        s.a_packets, s.a_lost, s.a_ptime_measured_ms, s.a_payload_bytes, s.a_buffers_rendered)
            t += String(format: "Sync: Latenz %.0f ms (automatisch erhöht: %d), Transit V %.2f ms / A %.2f ms, Drift %.2f ppm, Neuausrichtungen %llu\n",
                        s.latency_ms, s.latency_auto_raised, s.v_transit_ms, s.a_transit_ms, s.offset_drift_ppm, s.resyncs)
            t += String(format: "Lippensynchron-Messung: n=%llu, letzte %+.1f ms, Mittel %+.1f ms (Blitze %llu, Toneinsätze %llu)\n",
                        s.sync_measurements, s.sync_offset_last_ms, s.sync_offset_avg_ms, s.flashes_seen, s.onsets_seen)
            t += "PTP: aktiv \(s.ptp_enabled), gelockt \(s.ptp_synced), Domain \(s.ptp_domain), GM \(cString(s.ptp_grandmaster)), Master \(cString(s.ptp_master)), "
            t += String(format: "Pfadverzögerung %.1f µs, GM passt zu SDP: %d, Domains gesehen %d\n", s.ptp_path_delay_us, s.ptp_gm_matches_sdp, s.ptp_domains_seen)
            t += "Empfangspuffer: \(s.socket_buffer_bytes / 1024) KiB\n"
        }
        if let n = nmosActive { t += "NMOS IS-05 aktiv: master_enable=\(String(describing: n.master_enable)), Ziel \(n.transport_params?.first?.destination_ip ?? "-")\n" }
        t += "\nEreignisse:\n"
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        for e in log.suffix(80) { t += "\(f.string(from: e.date)) \(e.text)\n" }
        return t
    }
}
