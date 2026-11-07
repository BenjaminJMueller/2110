import AppKit
import Foundation
import ST2110Kit
import SwiftUI
import UniformTypeIdentifiers

enum AppMode: String, CaseIterable, Identifiable {
    case receive = "Empfangen", send = "Senden", analyze = "Analysieren"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .receive: return "play.rectangle"
        case .send: return "dot.radiowaves.up.forward"
        case .analyze: return "waveform.path.ecg.rectangle"
        }
    }
}

enum SidebarItem: Hashable {
    case demo
    case saved(UUID)
    case discovered(String)
}

struct EditorRequest: Identifiable {
    let id = UUID()
    var source: SavedSource
    var isNew: Bool
}

@MainActor
@Observable
final class AppModel {
    var settings: AppSettings {
        didSet {
            settings.save()
            if oldValue.appearance != settings.appearance { applyAppearance() }
            if oldValue.mdnsDiscovery != settings.mdnsDiscovery || oldValue.registryURL != settings.registryURL
                || oldValue.manualNodes != settings.manualNodes {
                discovery.start(settings: settings)
            }
        }
    }
    private(set) var saved: [SavedSource]
    var selection: SidebarItem?
    var editor: EditorRequest?
    var showOnboarding = false
    var showManualEntry = false
    var showAddNode = false
    var showImporter = false
    var inspectorShown = false
    var isFullScreen = false
    var alert: String?
    var mode: AppMode = .receive
    var explainerPage = 0

    let store = SourceStore()
    let player = PlayerController()
    let discovery = NMOSDiscovery()
    let interfaces = NetworkInterfaceList()
    let audioDevices = AudioDeviceList()
    let sender = SenderController()
    let analysis = AnalysisModel()
    let output: ExternalOutput

    var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(v) (\(b))"
    }

    init() {
        GStreamerEnvironment.setUp()
        output = ExternalOutput(sink: player.sink)
        settings = AppSettings.load()
        saved = store.load()
        showOnboarding = !settings.onboardingDone
        player.interfacesProvider = { [weak self] in self?.interfaces.interfaces ?? [] }
        player.audioDeviceResolver = { [weak self] uid in
            guard !uid.isEmpty, let d = self?.audioDevices.device(uid: uid) else { return 0 }
            return Int(d.id)
        }
        player.refreshSource = { [weak self] src in await self?.refreshNMOS(src) }
        discovery.start(settings: settings)
        sender.interfacesProvider = { [weak self] in self?.interfaces.interfaces ?? [] }
        sender.settingsProvider = { [weak self] in self?.settings ?? AppSettings() }
        applyAppearance()
        if let e = GStreamerEnvironment.initError {
            alert = "Die Medienkomponente (GStreamer) konnte nicht gestartet werden: \(e)"
        } else if !GStreamerEnvironment.missingPlugins.isEmpty {
            alert = "Es fehlen Bestandteile der Medienkomponente: \(GStreamerEnvironment.missingPlugins). Bitte die App neu installieren."
        }
    }

    func applyAppearance() {
        switch settings.appearance {
        case 1: NSApp?.appearance = NSAppearance(named: .aqua)
        case 2: NSApp?.appearance = NSAppearance(named: .darkAqua)
        default: NSApp?.appearance = nil
        }
    }

    /// Mitschnitt aufzeichnen und danach automatisch analysieren.
    func recordAndAnalyze(seconds: Int) {
        guard let url = player.startRecording(seconds: seconds) else {
            alert = "Aufzeichnen ist nur während des Empfangs möglich."
            return
        }
        let sdps = [player.current?.videoSDP, player.current?.audioSDP].compactMap { $0 }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds + 1) * 1_000_000_000)
            player.stopRecording()
            analysis.sdpTexts = sdps
            analysis.open(url)
            mode = .analyze
        }
    }

    // MARK: Auswahl und Wiedergabe

    func activate(_ item: SidebarItem?) {
        guard let item else { return }
        switch item {
        case .demo:
            player.playDemo(settings: settings)
        case .saved(let id):
            guard var s = saved.first(where: { $0.id == id }) else { return }
            s.lastUsed = Date()
            upsert(s)
            if s.nmos != nil {
                Task {
                    let refreshed = await refreshNMOS(s) ?? s
                    player.play(refreshed, settings: settings)
                    await updateNMOSStatus(refreshed)
                }
            } else {
                player.play(s, settings: settings)
            }
        case .discovered(let id):
            guard let d = discovery.sources.first(where: { $0.id == id }) else { return }
            Task { await playDiscovered(d, audioSenderID: d.audio.first?.id) }
        }
    }

    func togglePlay() {
        if player.isActive { player.stop() } else if player.current != nil {
            player.togglePlay(settings: settings)
        } else {
            activate(selection)
        }
    }

    /// Holt die SDPs eines NMOS-Senders und speichert die Quelle (inkl. NMOS-Bezug,
    /// damit sie beim nächsten Start aktualisiert angeboten wird).
    func playDiscovered(_ d: DiscoveredSource, audioSenderID: String?) async {
        let client = discovery.client
        var videoSDP: String?
        var audioSDP: String?
        var problems: [String] = []
        if let v = d.video {
            do { videoSDP = try await client.sdp(for: v, connectionAPI: d.connectionAPI) } catch { problems.append(error.localizedDescription) }
        }
        let audioSender = d.audio.first(where: { $0.id == audioSenderID }) ?? d.audio.first
        if let a = audioSender {
            do { audioSDP = try await client.sdp(for: a, connectionAPI: d.connectionAPI) } catch { problems.append(error.localizedDescription) }
        }
        guard videoSDP != nil || audioSDP != nil else {
            alert = problems.joined(separator: "\n")
            return
        }
        var ref = NMOSReference(apiBase: d.apiBase, connectionAPI: d.connectionAPI, videoSenderID: d.video?.id,
                                audioSenderID: audioSender?.id)
        ref.videoSenderVersion = d.video?.version
        ref.audioSenderVersion = audioSender?.version
        var src = saved.first(where: { $0.nmos?.videoSenderID == ref.videoSenderID && $0.nmos?.audioSenderID == ref.audioSenderID })
            ?? SavedSource(name: "\(d.deviceLabel) – \(d.title)", origin: .nmos)
        src.videoSDP = videoSDP
        src.audioSDP = audioSDP
        src.nmos = ref
        src.lastUsed = Date()
        upsert(src)
        player.play(src, settings: settings)
        for p in problems { player.addLog(.warning, p) }
        await updateNMOSStatus(src)
    }

    /// Lädt die SDPs einer NMOS-Quelle neu. Liefert die Quelle nur zurück,
    /// wenn sich eine SDP geändert hat.
    func refreshNMOS(_ s: SavedSource) async -> SavedSource? {
        guard let ref = s.nmos else { return nil }
        let client = discovery.client
        var updated = s
        var changed = false
        for (id, isVideo) in [(ref.videoSenderID, true), (ref.audioSenderID, false)] {
            guard let id else { continue }
            guard let sender = try? await client.sender(base: ref.apiBase, id: id),
                  let sdp = try? await client.sdp(for: sender, connectionAPI: ref.connectionAPI) else { continue }
            if isVideo, sdp != s.videoSDP { updated.videoSDP = sdp; changed = true }
            if !isVideo, sdp != s.audioSDP { updated.audioSDP = sdp; changed = true }
        }
        guard changed else { return nil }
        upsert(updated)
        return updated
    }

    func updateNMOSStatus(_ s: SavedSource) async {
        guard let ref = s.nmos, let conn = ref.connectionAPI, let id = ref.videoSenderID ?? ref.audioSenderID else {
            player.nmosActive = nil
            return
        }
        player.nmosActive = try? await discovery.client.activeParams(connectionAPI: conn, senderID: id)
    }

    // MARK: Quellen verwalten

    /// Den eigenen Sendestrom auf diesem Mac empfangen (über die eigene Netzwerkschnittstelle bzw. Loopback).
    func receiveOwnStream() {
        guard sender.isSending, sender.videoSDP != nil || sender.audioSDP != nil else { return }
        let name = "Eigener 2110-Viewer-Strom"
        var src = saved.first(where: { $0.name == name }) ?? SavedSource(name: name, origin: .sdp)
        src.videoSDP = sender.videoSDP
        src.audioSDP = sender.audioSDP
        upsert(src)
        mode = .receive
        if selection == .saved(src.id) { activate(selection) } else { selection = .saved(src.id) }
    }

    func upsert(_ s: SavedSource) {
        if let i = saved.firstIndex(where: { $0.id == s.id }) { saved[i] = s } else { saved.append(s) }
        store.save(saved)
    }

    func delete(_ id: UUID) {
        if player.current?.id == id { player.stop() }
        saved.removeAll { $0.id == id }
        store.save(saved)
        if selection == .saved(id) { selection = nil }
    }

    func duplicate(_ id: UUID) {
        guard var s = saved.first(where: { $0.id == id }) else { return }
        s.id = UUID()
        s.name += " (Kopie)"
        s.createdAt = Date()
        upsert(s)
    }

    func newSource() {
        editor = EditorRequest(source: SavedSource(name: "Neue Quelle", origin: .sdp), isNew: true)
    }

    func edit(_ id: UUID) {
        guard let s = saved.first(where: { $0.id == id }) else { return }
        editor = EditorRequest(source: s, isNew: false)
    }

    /// Importiert SDP-Dateien. Video- und Audio-SDPs werden zu einer Quelle
    /// zusammengefasst; der Editor zeigt das Ergebnis zur Kontrolle.
    func importFiles(_ urls: [URL]) {
        var texts: [(name: String, text: String)] = []
        for u in urls {
            let access = u.startAccessingSecurityScopedResource()
            defer { if access { u.stopAccessingSecurityScopedResource() } }
            if let t = (try? String(contentsOf: u, encoding: .utf8)) ?? (try? String(contentsOf: u, encoding: .isoLatin1)) {
                texts.append((name: u.deletingPathExtension().lastPathComponent, text: t))
            }
        }
        guard !texts.isEmpty else {
            alert = "Die Datei konnte nicht gelesen werden."
            return
        }
        importTexts(texts)
    }

    func importTexts(_ texts: [(name: String, text: String)]) {
        var src = SavedSource(name: texts.first?.name ?? "Neue Quelle", origin: .sdp)
        var nonSDP: [String] = []
        for (name, t) in texts {
            guard SDPText.looksLikeSDP(t) else { nonSDP.append(name); continue }
            for sec in SDPText.sections(t) {
                switch sec.kind {
                case .video where src.videoSDP == nil: src.videoSDP = sec.text
                case .audio where src.audioSDP == nil: src.audioSDP = sec.text
                default: break
                }
            }
        }
        if src.videoSDP == nil && src.audioSDP == nil {
            alert = nonSDP.isEmpty ? "Keine Video- oder Audiobeschreibung gefunden." : "„\(nonSDP.joined(separator: "“, „"))“ ist keine SDP-Datei."
            return
        }
        if let v = src.videoSDP, let first = SDPMedia.parse(v).media.first, !first.sessionName.isEmpty, texts.count > 1 {
            src.name = first.sessionName
        }
        editor = EditorRequest(source: src, isNew: true)
    }

    func pasteSDP() {
        guard let t = NSPasteboard.general.string(forType: .string), !t.isEmpty else {
            alert = "Die Zwischenablage enthält keinen Text."
            return
        }
        importTexts([("Eingefügte Quelle", t)])
    }
}
