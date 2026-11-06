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
                        .frame(height: 30)
                }
                HStack(spacing: 12) {
                    Button {
                        model.togglePlay()
                    } label: {
                        Label(p.isActive ? "Stopp" : "Start", systemImage: p.isActive ? "stop.fill" : "play.fill")
                            .frame(minWidth: 70)
                    }
                    .controlButtonStyle(prominent: !p.isActive)
                    .disabled(p.current == nil && model.selection == nil)
                    .help(p.isActive ? "Wiedergabe stoppen (Leertaste)" : "Wiedergabe starten (Leertaste)")

                    StatusPill()

                    Spacer(minLength: 8)

                    MonitorPicker()

                    Button {
                        model.settings.muted.toggle()
                        p.setMute(model.settings.muted)
                    } label: {
                        Image(systemName: model.settings.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .frame(width: 18)
                    }
                    .controlButtonStyle()
                    .accessibilityLabel(model.settings.muted ? "Stummschaltung aufheben" : "Stummschalten")
                    .help("Stummschalten (M)")

                    Slider(value: Binding(get: { model.settings.volume }, set: {
                        model.settings.volume = $0
                        p.setVolume($0)
                    }), in: 0...1.5)
                    .frame(width: 120)
                    .accessibilityLabel("Lautstärke")
                    .accessibilityValue("\(Int(model.settings.volume * 100)) Prozent")

                    OutputPicker()

                    Button {
                        NSApp.keyWindow?.toggleFullScreen(nil)
                    } label: {
                        Image(systemName: model.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    }
                    .controlButtonStyle()
                    .accessibilityLabel(model.isFullScreen ? "Vollbild beenden" : "Vollbild")
                    .help("Vollbild (⌃⌘F)")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .controlSurface()
        }
    }
}

private struct StatusPill: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let (color, text) = status
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 9, height: 9).accessibilityHidden(true)
            Text(text).font(.callout).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(text)")
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
            case ST_SYNC_PTP: return (.green, "Empfang · PTP-synchronisiert")
            case ST_SYNC_RTP_ALIGNED: return (.green, "Empfang · zeitlich abgestimmt (ohne PTP)")
            default: return (.yellow, "Empfang · Vorschau, nicht lippensynchron")
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
                        Button(i + 1 < n ? "Kanäle \(i + 1) + \(i + 2)" : "Kanal \(i + 1)") { p.selectPair(i) }
                    }
                }
            }
            Section("Einzelkanal (auf beiden Seiten)") {
                ForEach(0..<n, id: \.self) { i in
                    Button("Kanal \(i + 1)") { p.monitorLeft = i; p.monitorRight = -1 }
                }
            }
            if n >= 2 {
                Section("Frei wählbares Paar") {
                    Menu("Links") {
                        ForEach(0..<n, id: \.self) { i in Button("Kanal \(i + 1)") { p.monitorLeft = i } }
                    }
                    Menu("Rechts") {
                        ForEach(0..<n, id: \.self) { i in Button("Kanal \(i + 1)") { p.monitorRight = i } }
                    }
                }
            }
        } label: {
            Label(label(n: n), systemImage: "headphones")
        }
        .fixedSize()
        .disabled(n == 0)
        .help("Abhören: Kanalpaar oder Einzelkanal wählen (⌘[ / ⌘])")
        .accessibilityLabel("Abhörauswahl: \(label(n: n))")
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
                    if model.settings.audioDeviceUID == d.uid { Label(d.name, systemImage: "checkmark") } else { Text(d.name) }
                }
            }
        } label: {
            Image(systemName: "hifispeaker")
        }
        .fixedSize()
        .help("Audioausgabegerät: \(currentName)")
        .accessibilityLabel("Audioausgabegerät: \(currentName)")
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
            let spacing: CGFloat = n > 16 ? 1 : 3
            let w = max(4, (geo.size.width - spacing * CGFloat(n - 1)) / CGFloat(n))
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(Array(levels.enumerated()), id: \.offset) { i, db in
                    VStack(spacing: 1) {
                        MeterBar(db: db, highlighted: i == left || i == right)
                        if n <= 32 {
                            Text("\(i + 1)").font(.system(size: 8)).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: w)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Pegel Kanal \(i + 1)\(i == left || i == right ? ", wird abgehört" : "")")
                    .accessibilityValue(db <= -119 ? "kein Signal" : String(format: "%.0f dBFS", db))
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
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.primary.opacity(highlighted ? 0.18 : 0.08))
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(db > -1 ? Color.red : (db > -9 ? Color.yellow : Color.green))
                    .frame(height: g.size.height * frac)
            }
            .overlay(RoundedRectangle(cornerRadius: 1.5).strokeBorder(highlighted ? Color.accentColor : .clear, lineWidth: 1))
        }
    }
}
