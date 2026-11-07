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
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 20) {
                    card("Quelle") {
                        LabeledContent("Quelle") {
                            Picker("Quelle", selection: sourceBinding) {
                                Text("Testbild mit 1-kHz-Ton").tag("bars")
                                Text("Lippensynchron-Test").tag("sync")
                                Text("Videodatei …").tag("file")
                                ForEach(CaptureFeeder.cameras, id: \.uniqueID) { c in Text(c.localizedName).tag("cam:" + c.uniqueID) }
                            }
                            .labelsHidden().fixedSize()
                        }
                        if case .file(let u) = s.source {
                            Divider()
                            LabeledContent("Datei") {
                                HStack {
                                    Text(u.lastPathComponent).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                                    Button("Ändern …") { importing = true }.controlSize(.small)
                                }
                            }
                            Text("Läuft in Echtzeit und in Schleife. macOS dekodiert H.264, HEVC, ProRes und AAC selbst.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if case .camera = s.source {
                            Divider()
                            LabeledContent("Mikrofon") {
                                Picker("Mikrofon", selection: $s.microphoneID) {
                                    Text("Standard").tag(String?.none)
                                    ForEach(CaptureFeeder.microphones, id: \.uniqueID) { m in Text(m.localizedName).tag(Optional(m.uniqueID)) }
                                }
                                .labelsHidden().fixedSize()
                            }
                        }
                    }
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
                                Text(s.audioChannels == 0 ? "aus" : String(s.audioChannels)).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                        Divider()
                        Toggle("Paketzeit 0,125 ms", isOn: ptimeBinding)
                            .toggleStyle(.switch)
                            .disabled(s.audioChannels > 8 || s.audioChannels == 0)
                            .help("Ab 9 Kanälen vorgeschrieben")
                        Text(rateText).font(.caption).foregroundStyle(rateWarning ? .orange : .secondary)
                    }
                    card("Netzwerk") {
                        LabeledContent("Video an") {
                            TextField("Multicast-Adresse", text: $s.videoAddress).frame(width: 150).monospacedDigit().multilineTextAlignment(.trailing)
                        }
                        Divider()
                        LabeledContent("Audio an") {
                            TextField("Multicast-Adresse", text: $s.audioAddress).frame(width: 150).monospacedDigit().multilineTextAlignment(.trailing)
                        }
                        Divider()
                        LabeledContent("Port") {
                            TextField("Port", value: $s.port, format: .number.grouping(.never)).frame(width: 80).multilineTextAlignment(.trailing)
                        }
                        HStack {
                            Spacer()
                            Button("Adressen vorschlagen") {
                                s.suggestAddresses(range: model.settings.multicastRange, interface: chosenInterface)
                            }
                            .controlSize(.small)
                        }
                        Divider()
                        Toggle("Zeit vom PTP-Grandmaster", isOn: $s.usePTP).toggleStyle(.switch)
                            .help("Übernimmt die Zeit passiv; die App wird nie Master")
                        Divider()
                        Toggle("Als NMOS-Quelle anbieten", isOn: $s.announceNMOS).toggleStyle(.switch)
                        Divider()
                        LabeledContent("Name im Netz") {
                            TextField("Name", text: $s.label).frame(maxWidth: 220).multilineTextAlignment(.trailing)
                        }
                    }
                    .disabled(s.isSending)

                    if let m = s.message {
                        Label(m, systemImage: "exclamationmark.triangle.fill").font(.callout)
                            .symbolRenderingMode(.multicolor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(width: 420)

                VStack(alignment: .leading, spacing: 20) {
                    card("An ein Gerät senden") {
                        if model.discovery.destinations.isEmpty {
                            Text("Keine NMOS-Empfänger gefunden. Ohne NMOS kann am Blackmagic-Gerät der 2110-Viewer-Strom im LCD-Menü (Outputs) bzw. in Converters Setup gewählt werden, sobald 2110 Viewer ihn anbietet. Alternativ die SDP-Datei weitergeben.")
                                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(model.discovery.destinations) { d in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(d.deviceLabel) – \(d.title)").font(.callout)
                                    Text(destinationDetail(d))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Verbinden") { confirmTarget = d }
                                    .controlSize(.small)
                                    .disabled(!s.isSending)
                            }
                        }
                        if let c = s.connectedDestination {
                            Label("Verbunden mit \(c)", systemImage: "link").font(.callout)
                        }
                    }
                    card("Status") {
                        if let st = s.stats, s.isSending {
                            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                                GridRow { Text("Bilder").foregroundStyle(.secondary); Text(String(st.frames_sent) + (st.frames_from_source > 0 ? " (aus Quelle)" : " (Testbild)")) }
                                GridRow { Text("Datenrate Video").foregroundStyle(.secondary); Text(String(format: "%.0f Mbit/s", locale: .current, st.video_mbps)) }
                                GridRow { Text("Pakete Video / Audio").foregroundStyle(.secondary); Text("\(st.video_packets) / \(st.audio_packets)") }
                                GridRow { Text("Verspätet gesendet").foregroundStyle(.secondary); Text(String(format: "%llu (max. %.0f µs)", locale: .current, st.late_packets, st.max_late_us)) }
                                GridRow { Text("Zeitbezug").foregroundStyle(.secondary); Text(st.ptp_locked != 0 ? "PTP, Grandmaster \(cString(st.ptp_grandmaster))" : "Systemzeit (kein PTP)") }
                                GridRow { Text("Audiopuffer").foregroundStyle(.secondary); Text(String(format: "%.0f ms, %llu Aussetzer", locale: .current, st.audio_fill_ms, st.audio_underruns)) }
                                if let p = s.nmosPort { GridRow { Text("NMOS-Knoten").foregroundStyle(.secondary); Text("Port " + String(p) + ", per mDNS angekündigt") } }
                            }
                            .font(.callout.monospacedDigit())
                        } else {
                            Text("Nicht aktiv.").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    card("SDP") {
                        if let v = s.videoSDP {
                            Text(([v] + (s.audioSDP.map { [$0] } ?? [])).joined(separator: "\n"))
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            HStack {
                                Button("Kopieren") { s.copySDP() }.controlSize(.small)
                                Button("Als Dateien sichern …") { s.saveSDP() }.controlSize(.small)
                            }
                        } else {
                            Text("Erscheint nach dem Start.").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    if !s.log.isEmpty {
                        card("Ereignisse") {
                            ForEach(s.log.suffix(8).reversed(), id: \.self) { Text($0).font(.caption.monospacedDigit()) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            }
            .padding(24)
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
            Text("„\(d.deviceLabel) – \(d.title)“ gibt danach den 2110-Viewer-Strom aus. Das ändert das Routing des Geräts für alle (IS-05).")
        }
        .onAppear {
            if s.videoAddress.isEmpty { s.suggestAddresses(range: model.settings.multicastRange, interface: chosenInterface) }
        }
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
                Text(s.isSending ? "Sendet" : "Bereit zum Senden").font(.title2.weight(.semibold))
                Text(s.isSending ? s.format.rawValue + " an " + s.videoAddress : "Quelle, Format und Netzwerk wählen, dann starten.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if s.isStarting { ProgressView().controlSize(.small) }
            Button {
                if s.isSending { s.stop() } else { Task { await s.start() } }
            } label: {
                Label(s.isSending ? "Beenden" : "Senden", systemImage: s.isSending ? "stop.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace))
                    .frame(minWidth: 100)
            }
            .controlButtonStyle(prominent: !s.isSending)
            .controlSize(.extraLarge)
            .disabled(s.isStarting)
            .keyboardShortcut(.return, modifiers: [.command])
            .help(s.isSending ? "Senden beenden (⌘↩)" : "Senden starten (⌘↩)")
        }
        .padding(16)
        .cardBackground(cornerRadius: 16)
    }

    private func card<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        GroupedBox(title) { content() }
    }
}
