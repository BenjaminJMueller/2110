import Charts
import SwiftUI
import UniformTypeIdentifiers

/// Analyse von Paketmitschnitten: Ströme, Befunde, ein Hauptdiagramm,
/// Netz (PTP, IGMP). Kein Live-Player.
struct AnalysisView: View {
    @Environment(AppModel.self) private var model
    @State private var importing = false

    var body: some View {
        let a = model.analysis
        Group {
            if let busy = a.busyFile {
                VStack(spacing: 12) {
                    ProgressView(value: a.progress ?? 0) { Text("Analysiere \(busy)") }
                        .frame(width: 360)
                    Text("Große Mitschnitte brauchen etwas Zeit; die App bleibt bedienbar.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let e = a.selected {
                if let r = e.report {
                    ReportView(entry: e, report: r)
                } else {
                    ContentUnavailableView("Analyse nicht möglich", systemImage: "exclamationmark.triangle", description: Text(e.error ?? ""))
                }
            } else {
                AnalysisEmptyView(importing: $importing)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            for u in urls where ["pcap", "pcapng", "cap"].contains(u.pathExtension.lowercased()) { model.analysis.open(u) }
            return true
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "pcap") ?? .data, UTType(filenameExtension: "pcapng") ?? .data, .data]) { r in
            if case .success(let u) = r { model.analysis.open(u) }
        }
        .toolbar {
            ToolbarItem {
                Button { importing = true } label: { Label("Mitschnitt öffnen", systemImage: "doc.badge.plus") }
                    .help("pcap- oder pcapng-Datei öffnen (z. B. aus Wireshark oder aus 2110 Viewer aufgezeichnet)")
            }
        }
    }
}

private struct AnalysisEmptyView: View {
    @Binding var importing: Bool

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform.path.ecg.rectangle").font(.system(size: 44, weight: .light)).foregroundStyle(.secondary)
            Text("Paketmitschnitt analysieren").font(.title2.weight(.medium))
            Text("pcap- oder pcapng-Datei hierher ziehen. 2110 Viewer findet die ST-2110-Ströme, prüft Verluste, Paketabstände, das Zeitverhalten nach ST 2110-21, Audio-Laufzeiten, PTP und IGMP.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 520)
            HStack(spacing: 12) {
                Button("Mitschnitt öffnen …") { importing = true }.controlButtonStyle(prominent: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                Label("Mitschnitt aus 2110 Viewer: beim Empfang unter Diagnose › Aufzeichnen", systemImage: "record.circle")
                Label("Hardware-Mitschnitt (genaueste Zeitwerte): Capture-Karte oder Spiegelport am Switch, z. B. mit Wireshark", systemImage: "network")
            }
            .font(.callout).foregroundStyle(.secondary)
            .padding(16)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ReportView: View {
    @Environment(AppModel.self) private var model
    let entry: AnalysisModel.Entry
    let report: AnalysisReport

    var body: some View {
        @Bindable var a = model.analysis
        HStack(spacing: 0) {
            List(selection: $a.selectedStream) {
                Section("Ströme") {
                    ForEach(report.streams) { s in
                        HStack(spacing: 8) {
                            Circle().fill(levelColor(s.worstLevel)).frame(width: 8, height: 8).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.summary).font(.callout.weight(.medium))
                                Text(s.destination).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        .tag(s.index)
                        .accessibilityLabel("\(s.kindTitle), \(s.summary), \(s.destination)")
                    }
                }
                Section("Netz") {
                    Label("PTP und IGMP", systemImage: "clock.arrow.2.circlepath").tag(-1)
                }
            }
            .listStyle(.sidebar)
            .frame(width: 250)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    CaptureHeader(entry: entry, report: report)
                    if a.selectedStream == -1 {
                        NetworkReport(report: report)
                    } else if let s = report.streams.first(where: { $0.index == a.selectedStream }) {
                        StreamReport(stream: s, thumbnail: entry.thumbnails[s.index], duration: report.capture.duration_s)
                    }
                }
                .padding(24)
                .frame(maxWidth: 1200, alignment: .leading)
            }
        }
    }
}

private func levelColor(_ l: Int) -> Color { l >= 2 ? .red : l == 1 ? .orange : .green }

private struct CaptureHeader: View {
    @Environment(AppModel.self) private var model
    let entry: AnalysisModel.Entry
    let report: AnalysisReport

    var body: some View {
        let c = report.capture
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.url.lastPathComponent).font(.title2.weight(.medium))
                Spacer()
                Button("Als JSON exportieren …") { model.analysis.exportJSON(entry) }.controlSize(.small)
            }
            Text(captureLine(c))
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            ForEach(c.findings ?? [], id: \.self) { f in FindingRow(finding: f) }
        }
    }
}

private struct FindingRow: View {
    let finding: AnalysisReport.Finding

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: finding.level >= 2 ? "xmark.octagon" : finding.level == 1 ? "exclamationmark.triangle" : "checkmark.circle")
                .foregroundStyle(levelColor(finding.level))
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(finding.text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel((finding.level >= 2 ? "Fehler: " : finding.level == 1 ? "Hinweis: " : "In Ordnung: ") + finding.text)
    }
}

private struct StatTile: View {
    let label: String
    let value: String
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 26, weight: .medium).monospacedDigit())
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

private struct StreamReport: View {
    let stream: AnalysisReport.Stream
    let thumbnail: NSImage?
    let duration: Double
    @State private var chart = "cinst"

    var body: some View {
        let s = stream
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(s.kindTitle).font(.title3.weight(.medium))
                Text(streamLine(s))
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                StatTile(label: "Datenrate", value: String(format: "%.0f Mbit/s", locale: .current, s.rate_mbps ?? 0))
                StatTile(label: "Verluste", value: s.lost.formatted(), note: lossNote)
                if let v = s.video {
                    StatTile(label: "Bildrate", value: String(format: "%.3f", locale: .current, v.fps ?? 0), note: "\(v.frames.formatted()) Bilder")
                    StatTile(label: "ST 2110-21", value: senderClass(v.st2110_21_class),
                             note: String(format: "Cmax %.0f · VRX %.0f", locale: .current, v.cinst.max, v.vrx.max))
                } else if let au = s.audio {
                    StatTile(label: "Paketzeit", value: String(format: "%g ms", locale: .current, au.ptime_ms ?? 0), note: String(au.channels) + (au.channels_from_sdp ? " Kanäle" : " Kanäle (geschätzt)"))
                    StatTile(label: "TS-DF max.", value: String(format: "%.0f µs", locale: .current, au.tsdf_us.max), note: "1-s-Fenster")
                }
            }
            if s.video != nil || s.audio != nil {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Picker("Diagramm", selection: $chart) {
                            ForEach(chartChoices, id: \.0) { Text($0.1).tag($0.0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 560)
                        Spacer()
                    }
                    MainChart(series: series, limits: limits, unit: unit)
                        .frame(height: 300)
                    Text(explanation).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .onAppear { if !chartChoices.contains(where: { $0.0 == chart }) { chart = chartChoices.first?.0 ?? "iat_us" } }
                .onChange(of: stream.index) { _, _ in chart = chartChoices.first?.0 ?? "iat_us" }
            }
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Befunde").font(.headline)
                    ForEach(s.findings, id: \.self) { FindingRow(finding: $0) }
                    if let anc = s.anc, !anc.did_sdid.isEmpty {
                        Text("DID/SDID: " + anc.did_sdid.map { String(format: "%02X/%02X (%d)", locale: .current, $0.did, $0.sdid, $0.count) }.joined(separator: ", "))
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 8) {
                    if let thumbnail {
                        Text("Bild aus dem Mitschnitt").font(.headline)
                        Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit)
                            .frame(width: 320)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .accessibilityLabel("Vorschaubild des Videostroms")
                    }
                    Text("Paketabstände").font(.headline)
                    IATHistogram(bins: s.iat_histogram).frame(width: 320, height: 120)
                }
            }
        }
    }

    private var lossNote: String? {
        let total = stream.packets + stream.lost
        guard total > 0 else { return nil }
        return String(format: "%.4f %% von %@", locale: .current, Double(stream.lost) / Double(total) * 100, total.formatted())
    }

    private var chartChoices: [(String, String)] {
        if stream.video != nil {
            return [("cinst", "Cinst"), ("vrx", "VRX"), ("packets_per_frame", "Pakete je Bild"), ("rtp_latency_ms", "RTP-Latenz"), ("iat_us", "Paketabstand")]
        }
        return [("tsdf_us", "TS-DF"), ("iat_us", "Paketabstand")]
    }

    private var series: AnalysisReport.Series? { stream.video?.series[chart] ?? stream.audio?.series[chart] }

    private var limits: [(String, Double)] {
        guard let v = stream.video else { return [] }
        switch chart {
        case "cinst": return [("Narrow", v.limits["cmax_narrow"].flatMap { $0 } ?? 0), ("Wide", v.limits["cmax_wide"].flatMap { $0 } ?? 0)]
        case "vrx": return [("Narrow", v.limits["vrx_narrow"].flatMap { $0 } ?? 0)]
        default: return []
        }
    }

    private var unit: String {
        switch chart {
        case "rtp_latency_ms": return "ms"
        case "iat_us", "tsdf_us": return "µs"
        case "packets_per_frame": return "Pakete"
        default: return "Pakete"
        }
    }

    private var explanation: String {
        switch chart {
        case "cinst": return "Cinst zeigt je Bild, wie viele Pakete sich im Modell-Netzpuffer stauen (ST 2110-21, Network Compatibility Model). Unter der Linie „Narrow“ ist der Sender so gleichmäßig, wie es empfindliche Empfänger erwarten. Bei Software-Mitschnitten sind die Werte nur Richtwerte."
        case "vrx": return "VRX ist die Füllung eines gedachten Empfängerpuffers, der ab dem ersten Paket eines Bildes gleichmäßig liest. Hohe Werte bedeuten Bursts."
        case "packets_per_frame": return "Pakete je Bild. Schwankungen deuten auf Verluste oder Formatwechsel hin."
        case "rtp_latency_ms": return "Abstand zwischen Ankunft des ersten Pakets und der Bildzeit im RTP-Zeitstempel. Aussagekräftig, wenn der aufzeichnende Rechner PTP-synchron war; sonst zeigt die Kurve nur Schwankungen."
        case "tsdf_us": return "TS-DF (Timestamped Delay Factor): Schwankung der Laufzeit der Audiopakete gegenüber ihren Zeitstempeln je Sekunde. Der Empfänger muss mindestens so viel puffern."
        default: return "Abstand zwischen aufeinanderfolgenden Paketen dieses Stroms."
        }
    }
}

private struct MainChart: View {
    let series: AnalysisReport.Series?
    let limits: [(String, Double)]
    let unit: String

    var body: some View {
        if let s = series, !s.t.isEmpty {
            let pts = zip(s.t, s.v).compactMap { t, v in v.map { (t, $0) } }
            Chart {
                ForEach(Array(pts.enumerated()), id: \.offset) { _, p in
                    LineMark(x: .value("Zeit (s)", p.0), y: .value(unit, p.1))
                        .foregroundStyle(Color.accentColor)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
                ForEach(Array(limits.enumerated()), id: \.offset) { i, l in
                    // nahe beieinander liegende Grenzen abwechselnd links und rechts beschriften
                    let align: Alignment = i % 2 == 0 ? .trailing : .leading
                    let label: String = l.0 + " " + String(format: "%g", locale: .current, l.1)
                    RuleMark(y: .value(l.0, l.1))
                        .foregroundStyle(Color.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .annotation(position: .top, alignment: align) {
                            Text(label).font(.caption).foregroundStyle(.secondary)
                        }
                }
            }
            .chartXAxisLabel("Zeit im Mitschnitt (s)")
            .chartYAxisLabel(unit)
            .chartXAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(Color.primary.opacity(0.08)); AxisValueLabel().font(.caption.monospacedDigit()) } }
            .chartYAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(Color.primary.opacity(0.08)); AxisValueLabel().font(.caption.monospacedDigit()) } }
            .accessibilityLabel("Diagramm \(unit) über die Zeit")
        } else {
            Text("Keine Messwerte für diese Darstellung.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct IATHistogram: View {
    let bins: [Int]
    private let labels = ["<1", "<2", "<5", "<10", "<20", "<50", "<100", "<200", "<500", "<1k", "<2k", "<5k", "<10k", "<20k", "<50k", "mehr"]

    var body: some View {
        Chart {
            ForEach(Array(bins.enumerated()), id: \.offset) { i, n in
                BarMark(x: .value("µs", labels[min(i, labels.count - 1)]), y: .value("Pakete", n))
                    .foregroundStyle(Color.secondary.opacity(0.7))
            }
        }
        .chartXAxis { AxisMarks { _ in AxisValueLabel().font(.system(size: 8)) } }
        .chartYAxis(.hidden)
        .accessibilityLabel("Verteilung der Paketabstände in Mikrosekunden")
    }
}

private struct NetworkReport: View {
    let report: AnalysisReport

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("PTP").font(.title3.weight(.medium))
            if report.ptp.isEmpty {
                Text("Keine PTP-Nachrichten im Mitschnitt.").foregroundStyle(.secondary)
            }
            ForEach(report.ptp) { p in
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                    GridRow { Text("Domain").foregroundStyle(.secondary); Text("\(p.domain)") }
                    GridRow { Text("Grandmaster").foregroundStyle(.secondary); Text(p.grandmaster.isEmpty ? "–" : p.grandmaster).monospacedDigit() }
                    GridRow { Text("Sendende Master").foregroundStyle(.secondary); Text("\(p.masters)").foregroundStyle(p.masters > 1 ? .red : .primary) }
                    GridRow { Text("Priorität 1 / 2, Klasse").foregroundStyle(.secondary); Text("\(p.priority1) / \(p.priority2), Clock Class \(p.clock_class)") }
                    GridRow { Text("Sync / Announce je s").foregroundStyle(.secondary); Text(String(format: "%.2f / %.2f%@", locale: .current, p.sync_rate ?? 0, p.announce_rate ?? 0, p.two_step ? " (Two-Step)" : "")).monospacedDigit() }
                    GridRow { Text("Delay-Req / -Resp").foregroundStyle(.secondary); Text("\(p.delay_req) / \(p.delay_resp)").monospacedDigit() }
                    GridRow { Text("UTC-Versatz").foregroundStyle(.secondary); Text("\(p.utc_offset) s") }
                }
                .font(.callout)
                .padding(16)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            }
            Text("IGMP").font(.title3.weight(.medium))
            Text(report.igmp.queries > 0 ? "Querier: \(report.igmp.querier) (\(report.igmp.queries) Abfragen, davon \(report.igmp.v3_queries) IGMPv3)" : "Keine IGMP-Abfragen gesehen. Ohne Querier kann der Switch Multicast nach einiger Zeit abschalten.")
                .font(.callout).foregroundStyle(report.igmp.queries > 0 ? .primary : .secondary)
            ForEach(report.igmp.groups, id: \.self) { g in
                Text("\(g.group): \(g.joins) Beitritte, \(g.leaves) Austritte").font(.callout.monospacedDigit())
            }
        }
    }
}

private func captureLine(_ c: AnalysisReport.Capture) -> String {
    var t: String = c.format + " · " + c.packets.formatted() + " Pakete · " + String(format: "%.1f", locale: .current, c.duration_s) + " s"
    t += " · Zeitauflösung " + String(c.timestamp_resolution_ns) + " ns"
    if c.software_capture { t += " · Software-Mitschnitt" }
    return t
}

private func streamLine(_ s: AnalysisReport.Stream) -> String {
    var t: String = s.source + " → " + s.destination + " · SSRC " + String(format: "%08X", locale: .current, s.ssrc) + " · PT " + String(s.payload_type)
    if s.sdp_matched { t += " · SDP zugeordnet" }
    return t
}

private func senderClass(_ c: String) -> String {
    switch c {
    case "N": return "Narrow"
    case "W": return "Wide"
    case "nicht konform": return "außerhalb"
    default: return "–"
    }
}
