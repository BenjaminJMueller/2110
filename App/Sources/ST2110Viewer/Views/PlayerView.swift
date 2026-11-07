import AppKit
import ST2110Core
import ST2110Kit
import SwiftUI

/// Videobild im Mittelpunkt; Bedienleiste darunter (im Fenster) bzw. bei
/// Mausbewegung eingeblendet (im Vollbild). Über dem Bild liegen keine
/// dauerhaften Glas- oder Transparenzeffekte.
struct PlayerView: View {
    @Environment(AppModel.self) private var model
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                VideoSurface(renderer: model.player.renderer)
                if SnapshotRunner.outputDir != nil { SnapshotVideo() }
                VideoOverlay()
                if model.isFullScreen && controlsVisible {
                    VStack {
                        Spacer()
                        ControlBar()
                            .padding(16)
                            .transition(.opacity)
                    }
                }
            }
            .onContinuousHover { _ in revealControls() }
            if !model.isFullScreen {
                VStack(spacing: 8) {
                    ControlBar()
                    OutputStatus()
                    HintBanner()
                }
                .padding(12)
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.space) {
            model.togglePlay()
            return .handled
        }
        .onKeyPress(.escape) {
            if model.isFullScreen { NSApp.keyWindow?.toggleFullScreen(nil); return .handled }
            return .ignored
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "mM")) { _ in
            model.settings.muted.toggle()
            model.player.setMute(model.settings.muted)
            return .handled
        }
        .onAppear { focused = true }
    }

    private func revealControls() {
        guard model.isFullScreen else { return }
        withAnimation(.easeOut(duration: 0.15)) { controlsVisible = true }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { withAnimation(.easeIn(duration: 0.3)) { controlsVisible = false } }
        }
    }
}

/// Meldungen direkt im (schwarzen) Bildbereich, nur wenn kein Bild vorliegt,
/// sowie die Demo-Kennzeichnung.
private struct VideoOverlay: View {
    @Environment(AppModel.self) private var model
    @State private var noPicture = true

    var body: some View {
        let p = model.player
        ZStack {
            if noPicture {
                VStack(spacing: 14) {
                    Image(systemName: icon)
                        .font(.system(size: 52, weight: .thin))
                        .symbolRenderingMode(.hierarchical)
                        .symbolEffect(.pulse, options: .repeating, isActive: waiting)
                        .foregroundStyle(.white.opacity(0.7))
                    Text(title).font(.title2.weight(.semibold)).foregroundStyle(.white)
                    if let d = detail {
                        Text(d)
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.65))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 520)
                    }
                    if p.current == nil {
                        HStack(spacing: 12) {
                            Button { model.selection = .demo } label: { Label("Testbild ansehen", systemImage: "tv") }
                                .controlButtonStyle(prominent: true)
                            Button { model.showImporter = true } label: { Label("SDP öffnen …", systemImage: "doc") }
                                .controlButtonStyle()
                        }
                        .controlSize(.large)
                        .padding(.top, 6)
                    }
                }
                .padding(24)
                .environment(\.colorScheme, .dark)
                .transition(.opacity)
            }
            if p.isDemo {
                VStack {
                    HStack {
                        HStack(spacing: 6) {
                            Circle().fill(Color.orange).frame(width: 7, height: 7)
                            Text("Demo ohne Netzwerk")
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                        .environment(\.colorScheme, .dark)
                        Spacer()
                    }
                    Spacer()
                }
                .padding(12)
                .accessibilityLabel("Demo-Modus aktiv: Testbild und Testton, kein Netzwerkempfang")
            }
        }
        .task(id: p.current?.id) {
            while !Task.isCancelled {
                let np = p.sink.secondsSinceLastFrame > 1.0
                if np != noPicture { noPicture = np }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    /// Warten auf Signal: das Symbol pulsiert leise.
    private var waiting: Bool {
        let p = model.player
        return p.isActive && (p.coreState == ST_STATE_WAITING || p.coreState == ST_STATE_STARTING)
    }

    private var icon: String {
        let p = model.player
        if case .failed = p.phase { return "exclamationmark.triangle" }
        if p.current == nil { return "play.rectangle" }
        if p.video == nil && !p.isDemo && p.audio != nil { return "speaker.wave.2" }
        return "antenna.radiowaves.left.and.right.slash"
    }

    private var title: String {
        let p = model.player
        if case .failed = p.phase { return "Wiedergabe nicht möglich" }
        if p.current == nil { return "Keine Quelle ausgewählt" }
        if !p.isActive { return "Gestoppt" }
        if p.video == nil && p.audio != nil && !p.isDemo { return "Nur Audio" }
        switch p.coreState {
        case ST_STATE_STARTING: return p.effectiveSync == .automatic ? "Verbinde … (suche PTP-Grandmaster)" : "Verbinde …"
        case ST_STATE_WAITING: return "Warte auf Signal …"
        case ST_STATE_STALLED: return "Signal unterbrochen"
        case ST_STATE_ERROR: return "Fehler, neuer Versuch folgt"
        default: return "Kein Bild"
        }
    }

    private var detail: String? {
        let p = model.player
        if case .failed(let e) = p.phase { return e }
        if p.current == nil {
            return "Geräte im Netzwerk erscheinen links in der Seitenleiste. Sie können auch eine SDP-Datei in das Fenster ziehen."
        }
        return p.hints.first.map { $0.detail }
    }
}

/// Wichtigster Hinweis unter der Bedienleiste
private struct HintBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let p = model.player
        let warnings = (p.formatProblem.map { [$0] } ?? []) + p.mediaWarnings
        if let w = warnings.first {
            banner(icon: "exclamationmark.triangle.fill", color: .orange, title: "Format", text: w)
        } else if let h = p.hints.first, h.severity >= .warning, p.isActive {
            banner(icon: h.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill",
                   color: h.severity == .error ? .red : .orange,
                   title: h.title + (h.certainty == .suspected ? " (vermutet)" : ""), text: h.detail)
        }
    }

    private func banner(icon: String, color: Color, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(text).font(.callout).foregroundStyle(.secondary).lineLimit(3)
            }
            Spacer()
            Button("Diagnose") { model.inspectorShown = true }
                .controlSize(.small)
        }
        .padding(10)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}


/// Nur im Bildschirmfoto-Modus: Metal-Inhalte erscheinen nicht in
/// cacheDisplay, daher wird das Bild hier zusätzlich per CPU gezeigt.
private struct SnapshotVideo: View {
    @Environment(AppModel.self) private var model
    @State private var image: CGImage?
    var body: some View {
        Group {
            if let image { Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit) }
        }
        .task {
            while !Task.isCancelled {
                image = model.player.sink.secondsSinceLastFrame < 1 ? model.player.sink.cgImage(width: 960) : nil
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
    }
}

/// Zustand der Ausgabe auf dem zweiten Bildschirm, nur wenn es etwas zu sagen gibt.
private struct OutputStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let out = model.output
        if let m = out.message {
            HStack(spacing: 8) {
                Label(m, systemImage: "rectangle.on.rectangle").font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("OK") { out.dismissMessage() }.controlSize(.small)
            }
        } else if let name = out.activeName {
            HStack(spacing: 8) {
                Label("Ausgabe auf " + name, systemImage: "rectangle.on.rectangle.fill").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Beenden") { out.hide() }.controlSize(.small)
            }
        }
    }
}
