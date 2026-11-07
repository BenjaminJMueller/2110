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

    var body: some View {
        @Bindable var s = model.sender
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header(s)

                sourcePicker(s)

                HStack(alignment: .top, spacing: 20) {
                    card("Format") {
                        LabeledContent("Video") {
                            Picker("Video", selection: $s.format) {
                                ForEach(SenderController.Format.allCases) { f in Text(f.rawValue).tag(f) }
                            }
                            .labelsHidden().fixedSize()
                        }
                        Divider()
                        LabeledContent("Audiokanäle") {
                            Stepper(value: $s.audioChannels, in: 0...16) {
                                Text(tr(s.audioChannels == 0 ? "aus" : String(s.audioChannels))).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                        Divider()
                        Toggle("Paketzeit 0,125 ms", isOn: ptimeBinding)
                            .toggleStyle(.switch)
                            .disabled(s.audioChannels > 8 || s.audioChannels == 0)
                            .help("Ab 9 Kanälen vorgeschrieben")
                        Label(tr(rateText), systemImage: rateWarning ? "exclamationmark.triangle.fill" : "speedometer")
                            .font(.caption).foregroundStyle(rateWarning ? .orange : .secondary)
                    }
                    card("Netzwerk") {
                        LabeledContent("Video an") {
                            TextField("Multicast-Adresse", text: $s.videoAddress).frame(width: 140).monospacedDigit().multilineTextAlignment(.trailing)
                        }
                        Divider()
                        LabeledContent("Audio an") {
                            TextField("Multicast-Adresse", text: $s.audioAddress).frame(width: 140).monospacedDigit().multilineTextAlignment(.trailing)
                        }
                        Divider()
                        LabeledContent("Port") {
                            TextField("Port", value: $s.port, format: .number.grouping(.never)).frame(width: 70).multilineTextAlignment(.trailing)
                        }
                        Divider()
                        Toggle("Zeit vom PTP-Grandmaster", isOn: $s.usePTP).toggleStyle(.switch)
                            .help("Übernimmt die Zeit passiv; die App wird nie Master")
                        Divider()
                        Toggle("Als NMOS-Quelle anbieten", isOn: $s.announceNMOS).toggleStyle(.switch)
                        HStack {
                            TextField("Name im Netz", text: $s.label).textFieldStyle(.roundedBorder)
                            Button("Adressen vorschlagen") {
                                s.suggestAddresses(range: model.settings.multicastRange, interface: chosenInterface)
                            }
                            .controlSize(.small)
                        }
                    }
                }
                .disabled(s.isSending)

                if let m = s.message {
                    Label(tr(m), systemImage: "exclamationmark.triangle.fill").font(.callout)
                        .symbolRenderingMode(.multicolor)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let st = s.stats, s.isSending {
                    HStack(spacing: 12) {
                        Metric(label: "Bilder", value: st.frames_sent.formatted(), note: st.frames_from_source > 0 ? "aus Quelle" : "Testbild")
                        Metric(label: "Datenrate Video", value: String(format: "%.0f Mbit/s", locale: .current, st.video_mbps), note: nil)
                        Metric(label: "Zeitbezug", value: st.ptp_locked != 0 ? "PTP" : "Systemzeit", note: st.ptp_locked != 0 ? cString(st.ptp_grandmaster) : "kein PTP")
                        Metric(label: "Verspätet gesendet", value: st.late_packets.formatted(), note: String(format: "max. %.0f µs", locale: .current, st.max_late_us))
                    }
                    .transition(.opacity)
                }

                card("Ziel") {
                    Button { model.receiveOwnStream() } label: {
                        Label("Auf diesem Mac empfangen", systemImage: "laptopcomputer.and.arrow.down")
                    }
                    .controlButtonStyle()
                    .disabled(!s.isSending)
                    .help("Öffnet den eigenen Strom im Modus Empfangen, über das Netzwerk dieses Macs")
                    Divider()
                    if model.discovery.destinations.isEmpty {
                        Label("Keine NMOS-Empfänger gefunden. Am Blackmagic-Gerät den Strom im LCD-Menü unter „Outputs“ wählen.", systemImage: "info.circle")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(model.discovery.destinations) { d in
                        HStack {
                            Image(systemName: "rectangle.connected.to.line.below").foregroundStyle(Color.accentColor).frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tr(d.deviceLabel + " – " + d.title)).font(.callout)
                                Text(tr(destinationDetail(d))).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Verbinden") { confirmTarget = d }
                                .controlSize(.small)
                                .disabled(!s.isSending)
                        }
                    }
                    if let c = s.connectedDestination {
                        Label(tr("Verbunden mit \(c)"), systemImage: "link").font(.callout).foregroundStyle(.green)
                    }
                }

                if let v = s.videoSDP {
                    DisclosureGroup("SDP") {
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
                    }
                    .padding(14)
                    .cardBackground()
                }
                if !s.log.isEmpty {
                    DisclosureGroup("Ereignisse") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(s.log.suffix(8).reversed(), id: \.self) { Text(tr($0)).font(.caption.monospacedDigit()) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                    }
                    .padding(14)
                    .cardBackground()
                }
            }
            .frame(maxWidth: 860)
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
                    Picker("Mikrofon", selection: $sMicrophone) {
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
