import AppKit
import ST2110Core
import SwiftUI

struct ControlBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let p = model.player
        GlassGroup(spacing: 10) {
            VStack(spacing: 8) {
                if p.channelCount > 0 {
                    LevelMeters(levels: p.levels, left: p.monitorLeft, right: p.monitorRight)
                        .frame(height: 28)
                        .padding(.horizontal, 2)
                }
                HStack(spacing: 12) {
                    Button {
                        model.togglePlay()
                    } label: {
                        Label(tr(p.isActive ? "Stopp" : "Start"), systemImage: p.isActive ? "stop.fill" : "play.fill")
                            .contentTransition(.symbolEffect(.replace))
                            .frame(minWidth: 76)
                    }
                    .controlButtonStyle(prominent: !p.isActive)
                    .disabled(p.current == nil && model.selection == nil)
                    .help(tr(p.isActive ? "Wiedergabe stoppen (Leertaste)" : "Wiedergabe starten (Leertaste)"))

                    StatusPill()

                    Spacer(minLength: 8)

                    MonitorPicker()

                    Button {
                        model.settings.muted.toggle()
                        p.setMute(model.settings.muted)
                    } label: {
                        Image(systemName: model.settings.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 18, height: 18)
                    }
                    .iconButtonStyle()
                    .accessibilityLabel(tr(model.settings.muted ? "Stummschaltung aufheben" : "Stummschalten"))
                    .help("Stummschalten (M)")

                    Slider(value: Binding(get: { model.settings.volume }, set: {
                        model.settings.volume = $0
                        p.setVolume($0)
                    }), in: 0...1.5)
                    .frame(width: 120)
                    .accessibilityLabel("Lautstärke")
                    .accessibilityValue(tr("\(Int(model.settings.volume * 100)) Prozent"))

                    OutputPicker()

                    Button {
                        NSApp.keyWindow?.toggleFullScreen(nil)
                    } label: {
                        Image(systemName: model.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                            .frame(width: 18, height: 18)
                    }
                    .iconButtonStyle()
                    .accessibilityLabel(tr(model.isFullScreen ? "Vollbild beenden" : "Vollbild"))
                    .help("Vollbild (⌃⌘F)")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .controlSurface(cornerRadius: 22)
        }
    }
}

private struct StatusPill: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let (color, text) = status
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 9, height: 9).accessibilityHidden(true)
            Text(tr(text)).font(.callout).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tr("Status: \(text)"))
    }

    private var status: (Color, String) {
        let p = model.player
        if p.isDemo && p.isActive { return (.orange, "Demo läuft") }
        if case .failed = p.phase { return (.red, "Nicht abspielbar") }
        if !p.isActive { return (.gray, p.current == nil ? "Keine Quelle" : "Gestoppt") }
        switch p.coreState {
        case ST_STATE_STARTING: return (.yellow, "Verbinde …")
        case ST_STATE_WAITING: return (.yellow, "Warte auf Signal")
        case ST_STATE_STALLED: return (.red, "Signal unterbrochen")
        case ST_STATE_ERROR: return (.red, "Fehler")
        case ST_STATE_RECEIVING:
            guard let s = p.stats else { return (.green, "Empfang") }
            switch s.sync_active {
            case ST_SYNC_PTP: return (.green, "Empfang, mit PTP synchronisiert")
            case ST_SYNC_RTP_ALIGNED: return (.green, "Empfang, zeitlich abgestimmt (ohne PTP)")
            default: return (.yellow, "Vorschau, nicht lippensynchron")
            }
        default: return (.gray, "–")
        }
    }
}

/// Abhörauswahl: Stereopaare, Einzelkanäle oder freies Paar.
private struct MonitorPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let p = model.player
        let n = p.channelCount
        Menu {
            if n >= 2 {
                Section("Stereopaar") {
                    ForEach(Array(stride(from: 0, to: n, by: 2)), id: \.self) { i in
                        Button(tr(i + 1 < n ? "Kanäle \(i + 1) + \(i + 2)" : "Kanal \(i + 1)")) { p.selectPair(i) }
                    }
                }
            }
            Section("Einzelkanal (auf beiden Seiten)") {
                ForEach(0..<n, id: \.self) { i in
                    Button(tr("Kanal \(i + 1)")) { p.monitorLeft = i; p.monitorRight = -1 }
                }
            }
            if n >= 2 {
                Section("Frei wählbares Paar") {
                    Menu("Links") {
                        ForEach(0..<n, id: \.self) { i in Button(tr("Kanal \(i + 1)")) { p.monitorLeft = i } }
                    }
                    Menu("Rechts") {
                        ForEach(0..<n, id: \.self) { i in Button(tr("Kanal \(i + 1)")) { p.monitorRight = i } }
                    }
                }
            }
        } label: {
            Label(tr(label(n: n)), systemImage: "headphones")
        }
        .controlMenuStyle()
        .fixedSize()
        .disabled(n == 0)
        .help("Abhören: Kanalpaar oder Einzelkanal wählen (⌘[ / ⌘])")
        .accessibilityLabel(tr("Abhörauswahl: \(label(n: n))"))
    }

    private func label(n: Int) -> String {
        let p = model.player
        guard n > 0 else { return "Kein Audio" }
        if p.monitorRight < 0 { return "Kanal \(p.monitorLeft + 1)" }
        return "Kanäle \(p.monitorLeft + 1) + \(p.monitorRight + 1)"
    }
}

private struct OutputPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Button {
                choose("")
            } label: {
                if model.settings.audioDeviceUID.isEmpty { Label("Systemausgang", systemImage: "checkmark") } else { Text("Systemausgang") }
            }
            Divider()
            ForEach(model.audioDevices.devices) { d in
                Button {
                    choose(d.uid)
                } label: {
                    if model.settings.audioDeviceUID == d.uid { Label(tr(d.name), systemImage: "checkmark") } else { Text(tr(d.name)) }
                }
            }
        } label: {
            Image(systemName: "hifispeaker")
        }
        .controlMenuStyle(indicator: false)
        .fixedSize()
        .help(tr("Audioausgabegerät: \(currentName)"))
        .accessibilityLabel(tr("Audioausgabegerät: \(currentName)"))
    }

    private var currentName: String {
        model.audioDevices.device(uid: model.settings.audioDeviceUID)?.name ?? "Systemausgang"
    }

    private func choose(_ uid: String) {
        guard uid != model.settings.audioDeviceUID else { return }
        model.settings.audioDeviceUID = uid
        // Gerätewechsel erfordert einen Neustart der Audiokette
        if model.player.isActive, let c = model.player.current {
            if model.player.isDemo { model.player.playDemo(settings: model.settings) } else { model.player.play(c, settings: model.settings) }
        }
    }
}

/// Pegelanzeige aller Kanäle; abgehörte Kanäle hervorgehoben.
struct LevelMeters: View {
    let levels: [Float]
    let left: Int
    let right: Int

    var body: some View {
        GeometryReader { geo in
            let n = max(levels.count, 1)
            let spacing: CGFloat = n > 16 ? 2 : 4
            let w = max(4, (geo.size.width - spacing * CGFloat(n - 1)) / CGFloat(n))
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(Array(levels.enumerated()), id: \.offset) { i, db in
                    VStack(spacing: 1) {
                        MeterBar(db: db, highlighted: i == left || i == right)
                        if n <= 32 {
                            Text(tr("\(i + 1)")).font(.system(size: 9, weight: .medium).monospacedDigit()).foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: w)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(tr("Pegel Kanal \(i + 1)\(i == left || i == right ? ", wird abgehört" : "")"))
                    .accessibilityValue(tr(db <= -119 ? "kein Signal" : String(format: "%.0f dBFS", db)))
                }
            }
        }
    }
}

private struct MeterBar: View {
    let db: Float
    let highlighted: Bool

    var body: some View {
        GeometryReader { g in
            // Skala −60 … 0 dBFS
            let frac = CGFloat(max(0, min(1, (db + 60) / 60)))
            let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
            ZStack(alignment: .bottom) {
                shape.fill(Color.primary.opacity(highlighted ? 0.16 : 0.07))
                // Skala über die volle Höhe, sichtbar nur bis zum Pegel (wie Pegelanzeigen in Logic)
                LinearGradient(stops: [.init(color: .green, location: 0), .init(color: .green, location: 0.78),
                                       .init(color: .yellow, location: 0.88), .init(color: .red, location: 1)],
                               startPoint: .bottom, endPoint: .top)
                    .mask(alignment: .bottom) { Rectangle().frame(height: g.size.height * frac) }
                    .clipShape(shape)
            }
            .overlay(shape.strokeBorder(highlighted ? Color.accentColor : .clear, lineWidth: 1.5))
            .animation(.linear(duration: 0.08), value: frac)
        }
    }
}
