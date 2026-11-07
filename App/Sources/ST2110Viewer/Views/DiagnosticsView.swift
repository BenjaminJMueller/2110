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
            VStack(alignment: .leading, spacing: 16) {
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

                if !p.hints.isEmpty {
                    GroupedBox("Hinweise") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(p.hints) { h in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: h.severity == .error ? "xmark.octagon.fill" : h.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                                        .foregroundStyle(h.severity == .error ? .red : h.severity == .warning ? .orange : .secondary)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(tr(h.title + (h.certainty == .suspected ? " (vermutet)" : " (gemessen)")))
                                            .font(.callout.weight(.semibold))
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

                if !p.isDemo && p.isActive {
                    GroupedBox("Mitschnitt") {
                        VStack(alignment: .leading, spacing: 6) {
                            if p.isRecording, let s = p.stats {
                                Text(tr(String(format: "Zeichnet auf: %.0f s, %llu Pakete", locale: .current, s.rec_seconds, s.rec_packets))).font(.callout.monospacedDigit())
                            } else {
                                HStack {
                                    Button("10 s aufzeichnen und analysieren") { model.recordAndAnalyze(seconds: 10) }
                                    Button("60 s") { model.recordAndAnalyze(seconds: 60) }
                                }
                                .controlSize(.small)
                            }
                            Text("Speichert die empfangenen Pakete als pcapng im Ordner Filme › 2110-Viewer-Mitschnitte. Zeitstempel stammen vom Programm; für genaue ST-2110-21-Werte einen Hardware-Mitschnitt verwenden.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                section("Quelle") {
                    row("Name", p.current?.name ?? "–")
                    row("Herkunft", p.isDemo ? "Demo (synthetisch)" : origin)
                    if let i = p.interface { row("Schnittstelle", i.menuTitle) }
                    if let s = p.stats { row("Empfangspuffer", "\(s.socket_buffer_bytes / 1024 / 1024) MB") }
                }

                if let v = p.video {
                    section("Video laut SDP") {
                        row("Format", v.summary)
                        row("Farbraum / Kennlinie", "\(v.colorimetry.isEmpty ? "–" : v.colorimetry) / \(v.tcs.isEmpty ? "–" : v.tcs)\(v.range.isEmpty ? "" : " / " + v.range)")
                        row("Ziel", "\(v.destination):\(v.port), PT \(v.payloadType)")
                        row("Quelle (SSM)", v.sourceAddress.isEmpty ? "–" : v.sourceAddress)
                        row("Zeitbezug", v.refclk.isEmpty ? "nicht angegeben" : v.refclk)
                    }
                }
                if let s = p.stats, p.video != nil || p.isDemo {
                    section("Video gemessen") {
                        if p.isDemo {
                            Text("Demo: Das Testbild entsteht im Mac, es gibt keine Netzwerkpakete. Datenrate, Bildrate und Verluste werden erst beim Empfang gemessen.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        } else {
                        row("Datenrate", String(format: "%.0f Mbit/s", locale: .current, s.v_rate_mbps))
                        row("Bildrate (RTP)", String(format: "%.3f B/s", locale: .current, s.v_fps_measured))
                        row("Bildgröße", s.v_width_seen > 0 ? "\(s.v_width_seen)×\(s.v_height_seen)\(s.v_interlace_seen != 0 ? " (Halbbilder)" : "")" : "–")
                        row("Pakete / verloren", "\(s.v_packets) / \(s.v_lost)\(lossPct(s.v_lost, s.v_packets))")
                        row("Umsortiert / falscher PT", "\(s.v_reordered) / \(s.v_wrong_pt)")
                        row("Bilder empf. / gezeigt / verworfen", "\(s.v_frames) / \(s.v_frames_rendered) / \(s.v_frames_dropped)")
                        row("Letztes Paket vor", s.v_age_ms < 0 ? "–" : String(format: "%.0f ms", locale: .current, s.v_age_ms))
                        }
                    }
                }
                if let a = p.audio {
                    section("Audio laut SDP") {
                        row("Format", a.summary)
                        row("Ziel", "\(a.destination):\(a.port), PT \(a.payloadType)")
                        row("Quelle (SSM)", a.sourceAddress.isEmpty ? "–" : a.sourceAddress)
                        row("Zeitbezug", a.refclk.isEmpty ? "nicht angegeben" : a.refclk)
                    }
                }
                if let s = p.stats, p.audio != nil {
                    section("Audio gemessen") {
                        row("Paketzeit", s.a_ptime_measured_ms > 0 ? String(format: "%.3f ms (%d Byte Nutzlast)", locale: .current, s.a_ptime_measured_ms, s.a_payload_bytes) : "–")
                        row("Pakete / verloren", "\(s.a_packets) / \(s.a_lost)\(lossPct(s.a_lost, s.a_packets))")
                        row("Blöcke ausgegeben / verworfen", "\(s.a_buffers_rendered) / \(s.a_buffers_dropped)")
                        row("Letztes Paket vor", s.a_age_ms < 0 ? "–" : String(format: "%.0f ms", locale: .current, s.a_age_ms))
                    }
                }
                if let s = p.stats, !p.isDemo {
                    section("Synchronisation") {
                        row("Gewünscht", p.effectiveSync.title)
                        row("Wirksam", String(cString: st_sync_mode_name(s.sync_active)))
                        Text(tr(syncExplanation(s.sync_active)))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        row("Wiedergabepuffer", String(format: "%.0f ms%@", locale: .current, s.latency_ms, s.latency_auto_raised > 0 ? " (automatisch erhöht)" : ""))
                        row("Ankunft nach Aufnahme V / A", String(format: "%.1f / %.1f ms", locale: .current, s.v_transit_ms, s.a_transit_ms))
                        row("Verspätung max. V / A", String(format: "%.1f / %.1f ms", locale: .current, s.v_late_max_ms, s.a_late_max_ms))
                        if s.sync_active == ST_SYNC_RTP_ALIGNED {
                            row("Taktabweichung Sender ↔ Mac", String(format: "%.2f ppm", locale: .current, s.offset_drift_ppm))
                        }
                        row("Neuausrichtungen", "\(s.resyncs)")
                    }
                    section("Lippensynchron-Messung (Testsignal)") {
                        if s.sync_measurements > 0 {
                            row("Ton gegenüber Bild", String(format: "%+.1f ms (Mittel %+.1f ms, n = %llu)", locale: .current, s.sync_offset_last_ms, s.sync_offset_avg_ms, s.sync_measurements))
                        } else {
                            row("Messwerte", "noch keine (\(s.flashes_seen) Blitze, \(s.onsets_seen) Toneinsätze erkannt)")
                        }
                        Text("Misst den Abstand zwischen weißem Blitz in der Bildmitte und Ton-Einsatz an den Ausgabezeitstempeln. Dafür ein Blitz/Piep-Testsignal am SDI-Eingang einspeisen. Bildschirm- und Audiogeräte-Latenz sind nicht enthalten; positiv = Ton später.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    section("PTP") {
                        if s.ptp_enabled != 0 {
                            row("Status", s.ptp_synced != 0 ? "gelockt (passiver Follower, nur Slave)" : "nicht gelockt")
                            row("Domain", "\(s.ptp_domain)")
                            row("Grandmaster", cString(s.ptp_grandmaster).isEmpty ? "–" : cString(s.ptp_grandmaster))
                            row("Master", cString(s.ptp_master).isEmpty ? "–" : cString(s.ptp_master))
                            row("Pfadverzögerung", String(format: "%.1f µs", locale: .current, s.ptp_path_delay_us))
                            row("GM wie in SDP", s.ptp_gm_matches_sdp < 0 ? "unbekannt" : (s.ptp_gm_matches_sdp != 0 ? "ja" : "nein"))
                        } else {
                            row("Status", "nicht verwendet")
                        }
                        if let m = p.ptpMessage {
                            Text(tr(m)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if p.current?.nmos != nil {
                    SenderControlSection()
                }
                section("Ereignisse") {
                    ForEach(p.log.suffix(40).reversed()) { e in
                        HStack(alignment: .top) {
                            Text(e.date, style: .time).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Text(tr(e.text)).font(.caption).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding()
            .textSelection(.enabled)
        }
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
        return String(format: " (%.4f %%)", locale: .current, Double(lost) / Double(total) * 100)
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
    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        GroupedBox(title) {
            VStack(alignment: .leading, spacing: 6) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(tr(k))
            Spacer(minLength: 8)
            Text(tr(v)).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
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
                    HStack {
                        TextField("Multicast-Adresse", text: $newAddress).frame(width: 150)
                        TextField("Port", text: $newPort).frame(width: 70)
                        Button("Sender aktivieren / Ziel setzen …") { confirm = true }
                    }
                    .controlSize(.small)
                } else {
                    Text("Änderungen am Sender sind unter „Erweitert › NMOS & Adressen“ freizuschalten.")
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
