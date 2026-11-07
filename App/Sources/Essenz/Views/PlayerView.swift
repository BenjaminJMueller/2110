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
                VStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 44, weight: .light))
                    Text(title).font(.title2)
                    if let d = detail {
                        Text(d)
                            .font(.callout)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 560)
                    }
                }
                .foregroundStyle(.white.opacity(0.85))
                .padding()
                .accessibilityElement(children: .combine)
            }
            if p.isDemo {
                VStack {
                    HStack {
                        Text("DEMO · Testbild und Testton · kein Netzwerkempfang")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.orange, in: Capsule())
                            .foregroundStyle(.black)
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
        if p.current == nil { return "Quelle links auswählen" }
        if !p.isActive { return "Gestoppt" }
        if p.video == nil && p.audio != nil && !p.isDemo { return "Nur Audio" }
        switch p.coreState {
        case ST_STATE_STARTING: return p.effectiveSync == .automatic ? "Verbinde … (suche PTP-Grandmaster)" : "Verbinde …"
        case ST_STATE_WAITING: return "Warte auf Signal …"
        case ST_STATE_STALLED: return "Signal unterbrochen"
        case ST_STATE_ERROR: return "Fehler – neuer Versuch folgt"
        default: return "Kein Bild"
        }
    }

    private var detail: String? {
        let p = model.player
        if case .failed(let e) = p.phase { return e }
        if p.current == nil {
            return "Blackmagic-Geräte erscheinen automatisch unter „Im Netzwerk gefunden“. Alternativ SDP-Dateien in dieses Fenster ziehen."
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
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}
