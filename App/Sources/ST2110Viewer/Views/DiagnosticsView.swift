import AppKit
import ST2110Core
import ST2110Kit
import SwiftUI
import UniformTypeIdentifiers

/// Diagnose: erkannte Medienparameter, Paketstatistik, Synchronisation, PTP,
/// Netzwerk, Hinweise und Ereignisprotokoll. Der Bericht lässt sich kopieren
/// bzw. speichern, um Testergebnisse zurückzumelden.
struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let p = model.player
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Diagnose").font(.title3.weight(.semibold))
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(p.reportText(appVersion: model.appVersion), forType: .string)
                    } label: {
                        Label("Bericht kopieren", systemImage: "doc.on.doc")
                    }
                    .labelStyle(.iconOnly)
                    .iconButtonStyle()
                    .help("Diagnosebericht kopieren, etwa für eine Rückmeldung")
                    Button { saveReport() } label: {
                        Label("Bericht speichern …", systemImage: "square.and.arrow.down")
                    }
                    .labelStyle(.iconOnly)
                    .iconButtonStyle()
                    .help("Diagnosebericht als Textdatei speichern")
                }

                if p.isActive && !p.isDemo {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        LiveChartTile(title: "Datenrate", unit: "Mbit/s", series: p.live.rate)
                        LiveChartTile(title: "Bildrate", unit: "B/s", series: p.live.fps, format: "%.2f")
                        LiveChartTile(title: "Verlust Video", unit: "%", series: p.live.loss, format: "%.2f", warnAbove: 0.01,
                                      info: "Anteil der Videopakete, die in der letzten Sekunde gefehlt haben.")
                        LiveChartTile(title: "Laufzeit", unit: "ms", series: p.live.transit, format: "%.1f",
                                      info: "Zeit von der Aufnahme beim Sender bis zur Ankunft am Mac, aus den RTP-Zeitstempeln.")
                    }
                }

                if !p.hints.isEmpty {
                    GroupedBox("Hinweise") {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(p.hints) { h in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Image(systemName: h.severity == .error ? "xmark.octagon.fill" : h.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                                        .foregroundStyle(h.severity == .error ? .red : h.severity == .warning ? .orange : .blue)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(tr(h.title)).font(.callout.weight(.semibold))
                                        Text(tr(h.detail)).font(.callout).foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if let v = p.video {
                    section("Video") {
                        row("Format", v.summary)
                        row("Ziel", "\(v.destination):\(v.port)")
                        if let s = p.stats, !p.isDemo {
                            row("Bildgröße", s.v_width_seen > 0 ? "\(s.v_width_seen)×\(s.v_height_seen)\(s.v_interlace_seen != 0 ? "i" : "")" : "–")
                            row("Pakete", s.v_packets.formatted())
                            row("Verloren", s.v_lost.formatted() + lossPct(s.v_lost, s.v_packets))
                            row("Bilder gezeigt", s.v_frames_rendered.formatted())
                            row("Bilder verworfen", s.v_frames_dropped.formatted())
                        }
                        row("Farbraum", v.colorimetry.isEmpty ? "–" : v.colorimetry + (v.tcs.isEmpty ? "" : ", " + v.tcs))
                        if !v.sourceAddress.isEmpty { row("Quelle (SSM)", v.sourceAddress) }
                    }
                }
                if p.isDemo {
                    section("Demo") {
                        Label("Testbild aus dem Mac, ohne Netzwerkpakete", systemImage: "tv").font(.callout).foregroundStyle(.secondary)
                    }
                }
                if let a = p.audio {
                    section("Audio") {
                        row("Format", a.summary)
                        row("Ziel", "\(a.destination):\(a.port)")
                        if let s = p.stats {
                            if s.a_ptime_measured_ms > 0 { row("Paketzeit", String(format: "%.3f ms", locale: .current, s.a_ptime_measured_ms)) }
                            row("Pakete", s.a_packets.formatted())
                            row("Verloren", s.a_lost.formatted() + lossPct(s.a_lost, s.a_packets))
                        }
                    }
                }
                if let s = p.stats, !p.isDemo {
                    section("Synchronisation", info: syncExplanation(s.sync_active)) {
                        row("Modus", String(cString: st_sync_mode_name(s.sync_active)))
                        row("Puffer", String(format: "%.0f ms", locale: .current, s.latency_ms) + (s.latency_auto_raised > 0 ? " ↑" : ""))
                        row("Laufzeit V / A", String(format: "%.1f / %.1f ms", locale: .current, s.v_transit_ms, s.a_transit_ms))
                        if s.sync_active == ST_SYNC_RTP_ALIGNED {
                            row("Taktabweichung", String(format: "%.2f ppm", locale: .current, s.offset_drift_ppm))
                        }
                        row("Neuausrichtungen", s.resyncs.formatted())
                        if s.sync_measurements > 0 {
                            row("Ton zu Bild", String(format: "%+.1f ms", locale: .current, s.sync_offset_avg_ms))
                        }
                    }
                    section("PTP", info: p.ptpMessage) {
                        if s.ptp_enabled != 0 {
                            row("Status", s.ptp_synced != 0 ? "synchron" : "nicht synchron")
                            row("Domain", "\(s.ptp_domain)")
                            row("Grandmaster", cString(s.ptp_grandmaster).isEmpty ? "–" : cString(s.ptp_grandmaster))
                            row("Pfadverzögerung", String(format: "%.1f µs", locale: .current, s.ptp_path_delay_us))
                        } else {
                            row("Status", "nicht verwendet")
                        }
                    }
                }

                if !p.isDemo && p.isActive {
                    section("Mitschnitt", info: "Speichert die empfangenen Pakete als pcapng im Ordner Filme › 2110-Viewer-Mitschnitte und öffnet sie in der Analyse. Die Zeitstempel stammen vom Programm; genaue ST-2110-21-Werte liefert nur ein Hardware-Mitschnitt.") {
                        if p.isRecording, let s = p.stats {
                            Label(tr(String(format: "Zeichnet auf: %.0f s, %llu Pakete", locale: .current, s.rec_seconds, s.rec_packets)), systemImage: "record.circle")
                                .font(.callout.monospacedDigit()).foregroundStyle(.red)
                        } else {
                            HStack(spacing: 8) {
                                Button { model.recordAndAnalyze(seconds: 10) } label: { Label("10 s", systemImage: "record.circle") }
                                Button("60 s") { model.recordAndAnalyze(seconds: 60) }
                                Button { model.mode = .analyze; model.analysis.startLive(model: model) } label: { Label("Live", systemImage: "waveform.path.ecg") }
                                    .help("Analysiert den Empfang fortlaufend")
                            }
                            .controlSize(.small)
                        }
                    }
                }

                section("Quelle") {
                    row("Name", p.current?.name ?? "–")
                    row("Herkunft", p.isDemo ? "Demo" : origin)
                    if let i = p.interface { row("Schnittstelle", i.displayName) }
                }
                if p.current?.nmos != nil {
                    SenderControlSection()
                }
                section("Ereignisse") {
                    ForEach(collapsedLog(p.log.suffix(60))) { e in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(e.date, style: .time).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Text(tr(e.text)).font(.caption).lineLimit(2)
                            Spacer(minLength: 0)
                            if e.count > 1 {
                                Text("×\(e.count)").font(.caption2.monospacedDigit().weight(.semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Color(nsColor: .quaternarySystemFill), in: Capsule())
                            }
                        }
                        .help(tr(e.text))
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private struct CollapsedEvent: Identifiable {
        let id: Int
        let date: Date
        let text: String
        var count: Int
    }

    /// Gleiche aufeinanderfolgende Ereignisse zusammenfassen, neueste zuerst.
    private func collapsedLog<C: Collection>(_ log: C) -> [CollapsedEvent] where C.Element == PlayerController.LogEntry {
        var out: [CollapsedEvent] = []
        for e in log.reversed() {
            if let last = out.last, last.text == e.text { out[out.count - 1].count += 1; continue }
            out.append(CollapsedEvent(id: out.count, date: e.date, text: e.text, count: 1))
            if out.count >= 15 { break }
        }
        return out
    }

    private var origin: String {
        switch model.player.current?.origin {
        case .nmos: return "NMOS"
        case .manual: return "Manuelle Eingabe"
        case .sdp: return "SDP"
        case nil: return "–"
        }
    }

    private func lossPct(_ lost: UInt64, _ got: UInt64) -> String {
        let total = lost + got
        guard total > 0, lost > 0 else { return "" }
        return String(format: " (%.2f %%)", locale: .current, Double(lost) / Double(total) * 100)
    }

    private func syncExplanation(_ m: st_sync_mode) -> String {
        switch m {
        case ST_SYNC_PTP:
            return "Video und Audio werden über ihre RTP-Zeitstempel auf die Aufnahmezeit bezogen und nach der PTP-Uhr des Netzes ausgegeben. Der Mac nimmt nur passiv (Slave) an PTP teil."
        case ST_SYNC_RTP_ALIGNED:
            return "Video und Audio werden über ihre RTP-Zeitstempel (gemeinsamer Zeitbezug des Senders) zueinander ausgerichtet und mit der Uhr des Macs ausgegeben. Lippensynchron, solange der Sender beide Ströme aus derselben Uhr stempelt."
        default:
            return "Jeder Strom wird bei Ankunft wiedergegeben. Unterschiedliche Laufzeiten von Video und Audio werden nicht ausgeglichen. Lippensynchronität ist damit nicht gesichert."
        }
    }

    @ViewBuilder
    private func section<C: View>(_ title: String, info: String? = nil, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(tr(title)).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                if let info { InfoButton(text: info) }
            }
            .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 7) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .cardBackground()
        }
    }

    /// Zeile: Bezeichnung links in einer Zeile, Wert rechts (kürzt in der Mitte statt umzubrechen).
    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(tr(k)).lineLimit(1).fixedSize()
            Spacer(minLength: 8)
            Text(tr(v)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .monospacedDigit()
                .help(tr(v))
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }

    private func saveReport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm"
        panel.nameFieldStringValue = "ST2110-Diagnose_\(f.string(from: Date())).txt"
        if panel.runModal() == .OK, let url = panel.url {
            try? model.player.reportText(appVersion: model.appVersion).write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

/// IS-05: Senderstatus anzeigen und – nach Freischaltung in „Erweitert“ –
/// Sender aktivieren bzw. Zieladresse ändern.
private struct SenderControlSection: View {
    @Environment(AppModel.self) private var model
    @State private var confirm = false
    @State private var newAddress = ""
    @State private var newPort = ""
    @State private var message: String?

    var body: some View {
        let p = model.player
        GroupedBox("Sender (NMOS IS-05)") {
            VStack(alignment: .leading, spacing: 6) {
                if let a = p.nmosActive {
                    Text(tr("Aktiv: \(a.master_enable == true ? "ja" : "nein"), Ziel \(a.transport_params?.first?.destination_ip ?? "–"):\(a.transport_params?.first?.destination_port?.intValue.map(String.init) ?? "–")"))
                        .font(.callout)
                } else {
                    Text("Status nicht verfügbar (Gerät meldet keine Connection API).").font(.callout).foregroundStyle(.secondary)
                }
                if model.settings.allowSenderControl {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            TextField("Multicast-Adresse", text: $newAddress).frame(minWidth: 100, maxWidth: 160)
                            TextField("Port", text: $newPort).frame(minWidth: 50, maxWidth: 70)
                        }
                        Button("Sender aktivieren / Ziel setzen …") { confirm = true }
                    }
                    .controlSize(.small)
                } else {
                    Text("Freischalten unter Erweitert › NMOS & Adressen.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let m = message { Text(tr(m)).font(.caption).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog("Sender im Netzwerk verändern?", isPresented: $confirm) {
            Button("Ändern", role: .destructive) { Task { await apply() } }
        } message: {
            Text("Dies ändert die Konfiguration des Blackmagic-Geräts für alle Empfänger im Netz (IS-05).")
        }
    }

    private func apply() async {
        guard let src = model.player.current, let ref = src.nmos, let conn = ref.connectionAPI,
              let id = ref.videoSenderID ?? ref.audioSenderID else {
            message = "Keine Connection API bekannt."
            return
        }
        let ip = newAddress.trimmingCharacters(in: .whitespaces)
        if !ip.isEmpty {
            guard let addr = IPv4(ip), addr.isMulticast else { message = "Keine gültige Multicast-Adresse."; return }
            if let ranges = AddressRange.parseList(model.settings.multicastRange), !ranges.isEmpty,
               !ranges.contains(where: { $0.contains(addr) }) {
                message = "Adresse liegt außerhalb des eingestellten Multicast-Bereichs (\(model.settings.multicastRange))."
                return
            }
        }
        do {
            try await model.discovery.client.activateSender(connectionAPI: conn, senderID: id, enable: true,
                                                            destinationIP: ip.isEmpty ? nil : ip,
                                                            destinationPort: Int(newPort))
            message = "Übernommen. Die SDP wird neu geladen."
            await model.updateNMOSStatus(src)
            if let updated = await model.refreshNMOS(src) { model.player.play(updated, settings: model.settings) }
        } catch {
            message = error.localizedDescription
        }
    }
}
