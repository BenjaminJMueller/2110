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
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 20) {
                    card("Quelle") {
                        Picker("Quelle", selection: sourceBinding) {
                            Text("Testbild: Farbbalken und 1 kHz").tag("bars")
                            Text("Lippensynchron-Test: Blitz und Piep").tag("sync")
                            Text("Videodatei …").tag("file")
                            ForEach(CaptureFeeder.cameras, id: \.uniqueID) { c in Text("Kamera: \(c.localizedName)").tag("cam:" + c.uniqueID) }
                        }
                        .labelsHidden()
                        if case .file(let u) = s.source {
                            HStack {
                                Text(u.lastPathComponent).font(.callout).lineLimit(1)
                                Button("Andere Datei …") { importing = true }.controlSize(.small)
                            }
                            Text("macOS dekodiert die Datei selbst (z. B. H.264, HEVC, ProRes, AAC). Sie wird in Echtzeit und in Schleife gesendet.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if case .camera = s.source {
                            Picker("Mikrofon", selection: $s.microphoneID) {
                                Text("Standard").tag(String?.none)
                                ForEach(CaptureFeeder.microphones, id: \.uniqueID) { m in Text(m.localizedName).tag(Optional(m.uniqueID)) }
                            }
                        }
                    }
                    card("Format") {
                        Picker("Video", selection: $s.format) {
                            ForEach(SenderController.Format.allCases) { f in Text("\(f.rawValue) · YCbCr 4:2:2 10 Bit").tag(f) }
                        }
                        Stepper(channelsLabel, value: $s.audioChannels, in: 0...16)
                        Toggle("Paketzeit 0,125 ms (nötig ab 9 Kanälen)", isOn: ptimeBinding)
                            .disabled(s.audioChannels > 8 || s.audioChannels == 0)
                        Text(rateText).font(.caption).foregroundStyle(rateWarning ? .orange : .secondary)
                    }
                    card("Netz") {
                        LabeledContent("Video an") {
                            TextField("Multicast-Adresse", text: $s.videoAddress).frame(width: 150).monospacedDigit()
                        }
                        LabeledContent("Audio an") {
                            TextField("Multicast-Adresse", text: $s.audioAddress).frame(width: 150).monospacedDigit()
                        }
                        LabeledContent("Port") {
                            TextField("Port", value: $s.port, format: .number.grouping(.never)).frame(width: 80)
                        }
                        Button("Adressen vorschlagen") {
                            s.suggestAddresses(range: model.settings.multicastRange, interface: chosenInterface)
                        }
                        .controlSize(.small)
                        Toggle("Zeit vom PTP-Grandmaster übernehmen (passiv)", isOn: $s.usePTP)
                        Toggle("Als NMOS-Quelle im Netz anbieten", isOn: $s.announceNMOS)
                        TextField("Name im Netz", text: $s.label)
                    }
                    .disabled(s.isSending)

                    HStack(spacing: 12) {
                        Button {
                            if s.isSending { s.stop() } else { Task { await s.start() } }
                        } label: {
                            Label(s.isSending ? "Senden beenden" : "Senden starten", systemImage: s.isSending ? "stop.fill" : "dot.radiowaves.up.forward")
                                .frame(minWidth: 160)
                        }
                        .controlButtonStyle(prominent: !s.isSending)
                        .disabled(s.isStarting)
                        .keyboardShortcut(.return, modifiers: [.command])
                        if s.isStarting { ProgressView().controlSize(.small); Text("Starte, suche PTP …").font(.callout).foregroundStyle(.secondary) }
                    }
                    if let m = s.message {
                        Label(m, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(width: 420)

                VStack(alignment: .leading, spacing: 20) {
                    card("An ein Gerät senden") {
                        if model.discovery.destinations.isEmpty {
                            Text("Keine NMOS-Empfänger gefunden. Ohne NMOS kann am Blackmagic-Gerät der Essenz-Strom im LCD-Menü (Outputs) bzw. in Converters Setup gewählt werden, sobald Essenz ihn anbietet. Alternativ die SDP-Datei weitergeben.")
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
                                GridRow { Text("Bilder").foregroundStyle(.secondary); Text("\(st.frames_sent) (\(st.frames_from_source > 0 ? "aus Quelle" : "Testbild"))") }
                                GridRow { Text("Datenrate Video").foregroundStyle(.secondary); Text(String(format: "%.0f Mbit/s", st.video_mbps)) }
                                GridRow { Text("Pakete Video / Audio").foregroundStyle(.secondary); Text("\(st.video_packets) / \(st.audio_packets)") }
                                GridRow { Text("Verspätet gesendet").foregroundStyle(.secondary); Text(String(format: "%llu (max. %.0f µs)", st.late_packets, st.max_late_us)) }
                                GridRow { Text("Zeitbezug").foregroundStyle(.secondary); Text(st.ptp_locked != 0 ? "PTP, Grandmaster \(cString(st.ptp_grandmaster))" : "Systemzeit (kein PTP)") }
                                GridRow { Text("Audiopuffer").foregroundStyle(.secondary); Text(String(format: "%.0f ms, %llu Aussetzer", st.audio_fill_ms, st.audio_underruns)) }
                                if let p = s.nmosPort { GridRow { Text("NMOS-Knoten").foregroundStyle(.secondary); Text("Port \(p), per mDNS angekündigt") } }
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
            .padding(24)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.movie, .video, .audiovisualContent]) { r in
            if case .success(let u) = r {
                _ = u.startAccessingSecurityScopedResource()
                s.source = .file(u)
            }
        }
        .confirmationDialog("Gerät mit Essenz verbinden?", isPresented: Binding(get: { confirmTarget != nil }, set: { if !$0 { confirmTarget = nil } }), presenting: confirmTarget) { d in
            Button("Verbinden") { Task { await s.connect(d, client: model.discovery.client) } }
        } message: { d in
            Text("„\(d.deviceLabel) – \(d.title)“ gibt danach den Essenz-Strom aus. Das ändert das Routing des Geräts für alle (IS-05).")
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
        return d.pairingCertain ? kinds : kinds + " · Zuordnung vermutet"
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
        var t = String(format: "Datenrate ca. %.1f Gbit/s", g)
        if let i = chosenInterface { t += " · \(i.displayName)\(i.speedText.map { " (\($0))" } ?? "")" }
        if rateWarning { t += " – Verbindung zu langsam" }
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

    private func card<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
    }
}
