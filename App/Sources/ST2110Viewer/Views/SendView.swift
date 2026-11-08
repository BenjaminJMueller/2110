import AVFoundation
import ST2110Core
import ST2110Kit
import SwiftUI
import UniformTypeIdentifiers

/// Senden: Testbild, Datei oder Kamera als ST 2110-20/-30 ins Netz, als NMOS-Quelle
/// angeboten und auf Wunsch per IS-05 mit einem Empfänger verbunden.
struct SendView: View {
    @Environment(AppModel.self) private var model
    @State private var importing = false
    @State private var confirmTarget: DiscoveredDestination?
    @State private var showNetwork = false

    var body: some View {
        @Bindable var s = model.sender
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header(s)

                // Signalweg: Quelle → Format → Ziel
                HStack(spacing: 0) {
                    Menu {
                        Button { sourceBinding.wrappedValue = "bars" } label: { Label("Testbild mit 1-kHz-Ton", systemImage: "chart.bar.fill") }
                        Button { sourceBinding.wrappedValue = "sync" } label: { Label("Lippensynchron-Test", systemImage: "bolt.fill") }
                        Button { importing = true } label: { Label("Videodatei …", systemImage: "film.fill") }
                        if !CaptureFeeder.cameras.isEmpty {
                            Divider()
                            ForEach(CaptureFeeder.cameras, id: \.uniqueID) { c in
                                Button { sourceBinding.wrappedValue = "cam:" + c.uniqueID } label: { Label(tr(c.localizedName), systemImage: "video.fill") }
                            }
                        }
                    } label: {
                        PathCard(step: "Quelle", icon: sourceIcon(s), value: sourceTitle(s), detail: sourceDetail(s), active: s.isSending)
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                    .disabled(s.isSending)

                    PathConnector(active: s.isSending)

                    Menu {
                        Picker("Video", selection: $s.format) {
                            ForEach(SenderController.Format.allCases) { f in Text(f.rawValue).tag(f) }
                        }
                        .pickerStyle(.inline)
                        Divider()
                        Picker("Audiokanäle", selection: $s.audioChannels) {
                            Text("aus").tag(0)
                            ForEach([2, 4, 8, 16], id: \.self) { n in Text(tr("\(n) Kanäle")).tag(n) }
                        }
                        Toggle("Paketzeit 0,125 ms", isOn: ptimeBinding)
                            .disabled(s.audioChannels > 8 || s.audioChannels == 0)
                    } label: {
                        PathCard(step: "Format", icon: "rectangle.on.rectangle", value: s.format.rawValue,
                                 detail: formatDetail(s), active: s.isSending, warn: rateWarning)
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                    .disabled(s.isSending)

                    PathConnector(active: s.isSending)

                    Button { showNetwork = true } label: {
                        PathCard(step: "Ziel", icon: "network", value: s.videoAddress.isEmpty ? "–" : s.videoAddress,
                                 detail: destinationSummary(s), active: s.isSending)
                    }
                    .buttonStyle(.plain)
                    .disabled(s.isSending)
                    .popover(isPresented: $showNetwork, arrowEdge: .bottom) { networkForm(s).frame(width: 340).padding(16) }
                }

                if let m = s.message {
                    Label(tr(m), systemImage: "exclamationmark.triangle.fill").font(.callout)
                        .symbolRenderingMode(.multicolor)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if s.isSending {
                    HStack(spacing: 12) {
                        LiveChartTile(title: "Datenrate", unit: "Mbit/s", series: s.live.rate)
                        LiveChartTile(title: "Verspätet", unit: "Pakete/s", series: s.live.late, warnAbove: 100,
                                      info: "Pakete, die nicht zum geplanten Zeitpunkt hinausgingen. Gelegentliche Werte sind normal, dauerhaft hohe deuten auf einen ausgelasteten Mac hin.")
                        if s.audioChannels > 0 {
                            LiveChartTile(title: "Audiopuffer", unit: "ms", series: s.live.audioBuffer, tint: .green)
                        }
                    }
                    .transition(.opacity)
                }

                card("Empfänger") {
                    HStack {
                        Label("Dieser Mac", systemImage: "laptopcomputer").font(.callout)
                        Spacer()
                        Button("Empfangen") { model.receiveOwnStream() }
                            .controlSize(.small)
                            .disabled(!s.isSending)
                            .help("Öffnet den eigenen Strom im Modus Empfangen")
                    }
                    ForEach(model.discovery.destinations) { d in
                        Divider()
                        HStack {
                            Label(tr(d.deviceLabel + " – " + d.title), systemImage: "rectangle.connected.to.line.below").font(.callout)
                                .lineLimit(1)
                            Spacer()
                            if s.connectedDestination == d.deviceLabel + " – " + d.title {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            }
                            Button("Verbinden") { confirmTarget = d }
                                .controlSize(.small)
                                .disabled(!s.isSending)
                        }
                    }
                    if model.discovery.destinations.isEmpty {
                        HStack(spacing: 4) {
                            Text("Keine NMOS-Empfänger gefunden").font(.caption).foregroundStyle(.secondary)
                            InfoButton(text: "Ohne NMOS den Strom am Blackmagic-Gerät im LCD-Menü unter „Outputs“ oder in Converters Setup wählen, sobald 2110 Viewer sendet. Alternativ die SDP-Datei weitergeben.")
                        }
                    }
                }

                if let v = s.videoSDP {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(([v] + (s.audioSDP.map { [$0] } ?? [])).joined(separator: "\n"))
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            HStack {
                                Button("Kopieren") { s.copySDP() }.controlSize(.small)
                                Button("Als Dateien sichern …") { s.saveSDP() }.controlSize(.small)
                            }
                        }
                        .padding(.top, 8)
                    } label: { Label("SDP", systemImage: "doc.text").font(.callout) }
                    .padding(14)
                    .cardBackground()
                }
                if !s.log.isEmpty {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(s.log.suffix(8).reversed(), id: \.self) { Text(tr($0)).font(.caption.monospacedDigit()).lineLimit(2) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                    } label: { Label("Ereignisse", systemImage: "list.bullet").font(.callout) }
                    .padding(14)
                    .cardBackground()
                }
            }
            .frame(maxWidth: 900)
            .padding(28)
            .frame(maxWidth: .infinity)
            .animation(.smooth, value: s.isSending)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.movie, .video, .audiovisualContent]) { r in
            if case .success(let u) = r {
                _ = u.startAccessingSecurityScopedResource()
                s.source = .file(u)
            }
        }
        .confirmationDialog("Gerät mit 2110 Viewer verbinden?", isPresented: Binding(get: { confirmTarget != nil }, set: { if !$0 { confirmTarget = nil } }), presenting: confirmTarget) { d in
            Button("Verbinden") { Task { await s.connect(d, client: model.discovery.client) } }
        } message: { d in
            Text(tr("„\(d.deviceLabel) – \(d.title)“ gibt danach den 2110-Viewer-Strom aus. Das ändert das Routing des Geräts für alle (IS-05)."))
        }
        .onAppear {
            if s.videoAddress.isEmpty { s.suggestAddresses(range: model.settings.multicastRange, interface: chosenInterface) }
        }
    }

    private func sourceIcon(_ s: SenderController) -> String {
        switch s.source {
        case .bars: return "chart.bar.fill"
        case .syncTest: return "bolt.fill"
        case .file: return "film.fill"
        case .camera: return "video.fill"
        }
    }

    private func sourceTitle(_ s: SenderController) -> String {
        switch s.source {
        case .bars: return "Testbild"
        case .syncTest: return "Lippensynchron"
        case .file(let u): return u.deletingPathExtension().lastPathComponent
        case .camera: return cameraName(s) ?? "Kamera"
        }
    }

    private func sourceDetail(_ s: SenderController) -> String {
        switch s.source {
        case .bars: return "Farbbalken, 1 kHz"
        case .syncTest: return "Blitz und Piep"
        case .file: return "Videodatei in Schleife"
        case .camera: return "Kamera und Mikrofon"
        }
    }

    private func formatDetail(_ s: SenderController) -> String {
        let audio = s.audioChannels == 0 ? "ohne Ton" : "\(s.audioChannels) Kanäle"
        return audio + String(format: ", %.1f Gbit/s", locale: .current, s.format.gbps)
    }

    private func destinationSummary(_ s: SenderController) -> String {
        var parts = ["Port \(s.port)"]
        if s.usePTP { parts.append("PTP") }
        if s.announceNMOS { parts.append("NMOS") }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private func networkForm(_ sender: SenderController) -> some View {
        @Bindable var s = sender
        VStack(alignment: .leading, spacing: 10) {
            Text("Ziel").font(.headline)
            SettingRow("Video an") {
                TextField("Multicast-Adresse", text: $s.videoAddress).frame(width: 150).monospacedDigit().multilineTextAlignment(.trailing)
            }
            SettingRow("Audio an") {
                TextField("Multicast-Adresse", text: $s.audioAddress).frame(width: 150).monospacedDigit().multilineTextAlignment(.trailing)
            }
            SettingRow("Port") {
                TextField("Port", value: $s.port, format: .number.grouping(.never)).frame(width: 70).multilineTextAlignment(.trailing)
            }
            Button("Adressen vorschlagen") { s.suggestAddresses(range: model.settings.multicastRange, interface: chosenInterface) }
                .controlSize(.small)
            Divider()
            SwitchRow("Zeit vom PTP-Grandmaster", isOn: $s.usePTP)
            SwitchRow("Als NMOS-Quelle anbieten", isOn: $s.announceNMOS)
            SettingRow("Name im Netz") {
                TextField("Name", text: $s.label).frame(width: 170)
            }
            if case .camera = s.source {
                Divider()
                Picker("Mikrofon", selection: sMicrophone) {
                    Text("Standard").tag(String?.none)
                    ForEach(CaptureFeeder.microphones, id: \.uniqueID) { m in Text(tr(m.localizedName)).tag(Optional(m.uniqueID)) }
                }
            }
            Label(tr(rateText), systemImage: rateWarning ? "exclamationmark.triangle.fill" : "speedometer")
                .font(.caption).foregroundStyle(rateWarning ? .orange : .secondary)
        }
    }

    @ViewBuilder
    private func sourcePicker(_ s: SenderController) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quelle").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 4)
            HStack(spacing: 12) {
                SourceTile(icon: "chart.bar.fill", title: "Testbild", subtitle: "Farbbalken, 1 kHz", selected: sourceBinding.wrappedValue == "bars") { sourceBinding.wrappedValue = "bars" }
                SourceTile(icon: "bolt.fill", title: "Lippensynchron", subtitle: "Blitz und Piep", selected: sourceBinding.wrappedValue == "sync") { sourceBinding.wrappedValue = "sync" }
                SourceTile(icon: "film.fill", title: "Videodatei", subtitle: fileName(s) ?? "H.264, HEVC, ProRes", selected: sourceBinding.wrappedValue == "file") { importing = true }
                SourceTile(icon: "video.fill", title: "Kamera", subtitle: cameraName(s) ?? "Kamera wählen", selected: sourceBinding.wrappedValue.hasPrefix("cam:")) {
                    if let c = CaptureFeeder.cameras.first { sourceBinding.wrappedValue = "cam:" + c.uniqueID }
                }
            }
            .disabled(s.isSending)
            if case .camera = s.source {
                HStack(spacing: 16) {
                    Picker("Kamera", selection: sourceBinding) {
                        ForEach(CaptureFeeder.cameras, id: \.uniqueID) { c in Text(tr(c.localizedName)).tag("cam:" + c.uniqueID) }
                    }
                    .fixedSize()
                    Picker("Mikrofon", selection: sMicrophone) {
                        Text("Standard").tag(String?.none)
                        ForEach(CaptureFeeder.microphones, id: \.uniqueID) { m in Text(tr(m.localizedName)).tag(Optional(m.uniqueID)) }
                    }
                    .fixedSize()
                }
                .disabled(s.isSending)
                .padding(.leading, 4)
            }
        }
    }

    private var sMicrophone: Binding<String?> {
        let sender: SenderController = model.sender
        return Binding<String?>(get: { sender.microphoneID }, set: { sender.microphoneID = $0 })
    }

    private func fileName(_ s: SenderController) -> String? {
        if case .file(let u) = s.source { return u.lastPathComponent }
        return nil
    }

    private func cameraName(_ s: SenderController) -> String? {
        if case .camera(let id) = s.source { return CaptureFeeder.cameras.first { $0.uniqueID == id }?.localizedName }
        return nil
    }

    private func destinationDetail(_ d: DiscoveredDestination) -> String {
        var parts: [String] = []
        if d.video != nil { parts.append("Video") }
        if !d.audio.isEmpty { parts.append("Audio") }
        let kinds: String = parts.joined(separator: " + ")
        return d.pairingCertain ? kinds : kinds + " (Zuordnung vermutet)"
    }

    private var channelsLabel: String {
        let n: Int = model.sender.audioChannels
        let value: String = n == 0 ? "aus" : String(n)
        return "Audiokanäle: " + value
    }

    private var ptimeBinding: Binding<Bool> {
        let sender: SenderController = model.sender
        return Binding<Bool>(get: { sender.ptime125 || sender.audioChannels > 8 }, set: { sender.ptime125 = $0 })
    }

    private var chosenInterface: InterfaceSnapshot? {
        let list = model.interfaces.interfaces
        return model.settings.interfaceName.isEmpty ? InterfaceChoice.preferred(list, senderAddresses: [])
            : list.first { $0.name == model.settings.interfaceName }
    }

    private var rateText: String {
        let g = model.sender.format.gbps
        var t = String(format: "Datenrate ca. %.1f Gbit/s", locale: .current, g)
        if let i = chosenInterface { t += " über \(i.displayName)\(i.speedText.map { " (\($0))" } ?? "")" }
        if rateWarning { t += ". Die Verbindung ist dafür zu langsam." }
        return t
    }

    private var rateWarning: Bool {
        guard let i = chosenInterface else { return false }
        return i.isWireless || (i.linkSpeedBps > 0 && Double(i.linkSpeedBps) < model.sender.format.gbps * 1.1e9)
    }

    private var sourceBinding: Binding<String> {
        Binding(get: {
            switch model.sender.source {
            case .bars: return "bars"
            case .syncTest: return "sync"
            case .file: return "file"
            case .camera(let id): return "cam:" + (id ?? "")
            }
        }, set: { v in
            if v == "bars" { model.sender.source = .bars }
            else if v == "sync" { model.sender.source = .syncTest }
            else if v == "file" { importing = true }
            else if v.hasPrefix("cam:") { model.sender.source = .camera(String(v.dropFirst(4))) }
        })
    }

    private func header(_ s: SenderController) -> some View {
        HStack(spacing: 16) {
            Image(systemName: "dot.radiowaves.up.forward")
                .font(.system(size: 30, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(s.isSending ? Color.accentColor : Color.secondary)
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: s.isSending)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(tr(s.isSending ? "Sendet" : "Bereit zum Senden")).font(.title2.weight(.semibold))
                Text(tr(s.isSending ? s.format.rawValue + " an " + s.videoAddress : "Quelle, Format und Netzwerk wählen, dann starten."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if s.isStarting { ProgressView().controlSize(.small) }
            Button {
                if s.isSending { s.stop() } else { Task { await s.start() } }
            } label: {
                Label(tr(s.isSending ? "Beenden" : "Senden"), systemImage: s.isSending ? "stop.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace))
                    .frame(minWidth: 100)
            }
            .controlButtonStyle(prominent: !s.isSending)
            .controlSize(.extraLarge)
            .disabled(s.isStarting)
            .keyboardShortcut(.return, modifiers: [.command])
            .help(tr(s.isSending ? "Senden beenden (⌘↩)" : "Senden starten (⌘↩)"))
        }
        .padding(16)
        .cardBackground(cornerRadius: 16)
    }

    private func card<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        GroupedBox(title) { content() }
    }
}


/// Auswählbare Kachel für die Sendequelle.
private struct SourceTile: View {
    let icon: String
    let title: String
    let subtitle: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 26))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .frame(height: 32)
                Text(tr(title)).font(.callout.weight(.semibold)).foregroundStyle(.primary)
                Text(tr(subtitle)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16).padding(.horizontal, 8)
            .background(selected ? Color.accentColor.opacity(0.12) : Color(nsColor: .quaternarySystemFill),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color(nsColor: .separatorColor).opacity(0.5), lineWidth: selected ? 2 : 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .animation(.smooth(duration: 0.2), value: selected)
    }
}

/// Große Kennzahl beim Senden.
private struct Metric: View {
    let label: String
    let value: String
    let note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tr(label)).font(.caption).foregroundStyle(.secondary)
            Text(tr(value)).font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                .contentTransition(.numericText())
                .lineLimit(1).minimumScaleFactor(0.6)
            if let note { Text(tr(note)).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .cardBackground()
        .accessibilityElement(children: .combine)
    }
}


/// Station im Signalweg (Quelle, Format, Ziel).
private struct PathCard: View {
    let step: String
    let icon: String
    let value: String
    let detail: String
    let active: Bool
    var warn: Bool = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(tr(step)).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                Spacer()
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                    .opacity(hovering ? 1 : 0.6)
            }
            ZStack {
                Circle().fill((active ? Color.accentColor : Color.secondary).opacity(0.14))
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(active ? Color.accentColor : Color.primary)
            }
            .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(tr(value)).font(.title3.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 4) {
                    if warn { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                    Text(tr(detail)).lineLimit(1)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(nsColor: .quaternarySystemFill).opacity(hovering ? 1.6 : 1),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(active ? Color.accentColor.opacity(0.5) : Color(nsColor: .separatorColor).opacity(0.5), lineWidth: active ? 1.5 : 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
    }
}

/// Verbindung zwischen zwei Stationen; beim Senden laufen Punkte darauf.
private struct PathConnector: View {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: !active || reduceMotion)) { ctx in
            Canvas { g, size in
                let y = size.height / 2
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
                g.stroke(line, with: .color(active ? .accentColor : .secondary.opacity(0.4)), lineWidth: 2)
                if active && !reduceMotion {
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    for i in 0..<3 {
                        let f = (t * 0.8 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                        let x = size.width * f
                        g.fill(Path(ellipseIn: CGRect(x: x - 3, y: y - 3, width: 6, height: 6)), with: .color(.accentColor))
                    }
                }
            }
        }
        .frame(width: 36, height: 20)
        .accessibilityHidden(true)
    }
}
