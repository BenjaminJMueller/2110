import Charts
import ST2110Kit
import SwiftUI
import UniformTypeIdentifiers

/// Analyse von Paketmitschnitten und des laufenden Empfangs.
/// Links Mitschnitte und Ströme, rechts der Bericht in Karten.
struct AnalysisView: View {
    @Environment(AppModel.self) private var model
    @State private var importing = false

    var body: some View {
        let a = model.analysis
        Group {
            if let busy = a.busyFile {
                ProgressView(value: a.progress ?? 0) { Text(tr("Analysiere \(busy)")) }
                    .frame(width: 360)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if a.liveStarting || (a.liveRunning && !a.entries.contains(where: { a.isLive($0) })) {
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large)
                    Text(a.liveStarting ? "Empfang wird gestartet …" : "Erster Abschnitt wird aufgezeichnet …").foregroundStyle(.secondary)
                    Button("Abbrechen") { a.stopLive() }.controlButtonStyle()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let e = a.selected {
                if let r = e.report {
                    ReportView(entry: e, report: r)
                } else {
                    ContentUnavailableView("Analyse nicht möglich", systemImage: "exclamationmark.triangle", description: Text(tr(e.error ?? "")))
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
            ToolbarItemGroup {
                LiveSourceMenu(compact: true)
                Button { importing = true } label: { Label("Mitschnitt öffnen", systemImage: "doc.badge.plus") }
                    .help("Mitschnitt öffnen (pcap, pcapng)")
            }
        }
    }
}

/// Live-Analyse starten: laufender Empfang oder eine Quelle aus dem Netz bzw. den zuletzt verwendeten.
struct LiveSourceMenu: View {
    @Environment(AppModel.self) private var model
    var compact = false

    var body: some View {
        let a = model.analysis
        let recent = model.saved.sorted { ($0.lastUsed ?? $0.createdAt) > ($1.lastUsed ?? $1.createdAt) }.prefix(8)
        Menu {
            if a.liveRunning {
                Button("Live beenden") { a.stopLive() }
            } else {
                if model.player.isActive, !model.player.isDemo, let c = model.player.current {
                    Button(tr("Aktueller Empfang: \(c.name)")) { a.startLive(model: model) }
                    Divider()
                }
                if !model.discovery.sources.isEmpty {
                    Section("Im Netzwerk") {
                        ForEach(model.discovery.sources) { d in
                            Button(tr(d.title)) { a.startLive(model: model, source: .discovered(d.id)) }
                        }
                    }
                }
                if !recent.isEmpty {
                    Section("Zuletzt verwendet") {
                        ForEach(Array(recent)) { s in
                            Button(tr(s.name)) { a.startLive(model: model, source: .saved(s.id)) }
                        }
                    }
                }
                if model.discovery.sources.isEmpty && recent.isEmpty && !(model.player.isActive && !model.player.isDemo) {
                    Text("Keine Quelle gefunden")
                }
            }
        } label: {
            Label(tr(a.liveRunning ? "Live beenden" : "Live analysieren"), systemImage: a.liveRunning ? "stop.circle" : "dot.radiowaves.left.and.right")
        }
        .help("Den Empfang einer Quelle fortlaufend analysieren")
        .modifier(LiveMenuStyle(compact: compact))
    }
}

private struct LiveMenuStyle: ViewModifier {
    let compact: Bool
    func body(content: Content) -> some View {
        if compact { content } else { content.controlMenuStyle().fixedSize() }
    }
}

private struct AnalysisEmptyView: View {
    @Environment(AppModel.self) private var model
    @Binding var importing: Bool

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.path.ecg.rectangle")
                .font(.system(size: 56, weight: .thin))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
            HStack(spacing: 6) {
                Text("Analysieren").font(.title.weight(.semibold))
                InfoButton(text: "Die App findet die ST-2110-Ströme in einer pcap- oder pcapng-Datei und prüft Verluste, Zeitverhalten nach ST 2110-21, PTP und IGMP. Live zeichnet sie den Empfang in Abschnitten von 3 Sekunden auf und prüft jeden sofort. Die genauesten Zeitwerte liefert ein Hardware-Mitschnitt, etwa über den Spiegelport des Switches.")
            }
            Text("Mitschnitt hierher ziehen oder eine Quelle live prüfen.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button { importing = true } label: { Label("Mitschnitt öffnen …", systemImage: "folder") }
                    .controlButtonStyle(prominent: true)
                LiveSourceMenu()
            }
            .controlSize(.large)
            .padding(.top, 4)
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
        let a = model.analysis
        let key = a.selectedStream ?? report.defaultSelection
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if a.isLive(entry) {
                    LiveHeader(report: report)
                } else {
                    CaptureHeader(entry: entry, report: report)
                }
                if key == AnalysisModel.network {
                    NetworkReport(report: report)
                } else if let s = report.streams.first(where: { $0.key == key }) {
                    StreamReport(stream: s, thumbnail: entry.thumbnails[s.key], duration: report.capture.duration_s,
                                 trend: a.isLive(entry) ? a.liveTrends[s.key] : nil,
                                 missing: a.isLive(entry) && a.liveMissing.contains(s.key))
                }
            }
            .padding(20)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

private func levelColor(_ l: Int) -> Color { l >= 2 ? .red : l == 1 ? .orange : .green }

/// Kopf eines Mitschnitts: Name, Eckdaten, Export.
private struct CaptureHeader: View {
    @Environment(AppModel.self) private var model
    let entry: AnalysisModel.Entry
    let report: AnalysisReport

    var body: some View {
        let c = report.capture
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(tr(entry.url.lastPathComponent)).font(.title2.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Spacer()
                if entry.url.isFileURL && FileManager.default.fileExists(atPath: entry.url.path) {
                    Button { model.analysis.exportJSON(entry) } label: { Label("JSON", systemImage: "square.and.arrow.up") }
                        .controlButtonStyle()
                        .help("Bericht als JSON exportieren")
                }
            }
            HStack(spacing: 6) {
                Text(tr(captureLine(c))).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                if c.software_capture {
                    InfoButton(text: "Software-Mitschnitt: Die Zeitstempel stammen vom Betriebssystem. Cinst, VRX und Paketabstände sind daher Richtwerte.")
                }
            }
            ForEach(c.findings ?? [], id: \.self) { f in FindingRow(finding: f) }
        }
    }
}

/// Kopf der Live-Analyse: Quelle, pulsierendes „Live“, Abschnitt, Beenden.
private struct LiveHeader: View {
    @Environment(AppModel.self) private var model
    let report: AnalysisReport

    var body: some View {
        let a = model.analysis
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Text(tr(a.liveName)).font(.title2.weight(.semibold)).lineLimit(1)
                HStack(spacing: 5) {
                    Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.red)
                        .symbolEffect(.pulse, options: .repeating)
                    Text("Live").font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Color.red.opacity(0.12), in: Capsule())
                Text(tr("Abschnitt \(a.liveRounds)"))
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                InfoButton(text: "Die App zeichnet den Empfang in Abschnitten von 3 Sekunden auf und analysiert jeden sofort. Die Diagramme zeigen den Verlauf über die Abschnitte. Fehlt ein Strom in einem Abschnitt, bleibt sein letzter Stand stehen. Es ist ein Software-Mitschnitt, Zeitwerte wie Cinst und VRX sind daher Richtwerte.")
                Spacer()
                Button { a.stopLive() } label: { Label("Beenden", systemImage: "stop.fill") }
                    .controlButtonStyle(prominent: true)
            }
            let problems = (report.capture.findings ?? []).filter { $0.level >= 1 }
            ForEach(problems, id: \.self) { FindingRow(finding: $0) }
        }
    }
}

private struct FindingRow: View {
    let finding: AnalysisReport.Finding

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: finding.level >= 2 ? "xmark.octagon.fill" : finding.level == 1 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(levelColor(finding.level))
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(tr(finding.text)).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tr((finding.level >= 2 ? "Fehler: " : finding.level == 1 ? "Hinweis: " : "In Ordnung: ") + finding.text))
    }
}

private struct StatTile: View {
    let label: String
    let value: String
    var note: String?
    var info: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(tr(label)).font(.caption).foregroundStyle(.secondary)
                if let info { InfoButton(text: info) }
            }
            Text(tr(value)).font(.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.7)
                .contentTransition(.numericText())
            Text(tr(note ?? " ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .cardBackground()
        .accessibilityElement(children: .combine)
    }
}

/// Karte mit Überschrift (und optionalem Info-Knopf).
private struct Card<Content: View, Accessory: View>: View {
    let title: String
    var info: String?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text(tr(title)).font(.headline)
                if let info { InfoButton(text: info) }
                Spacer(minLength: 8)
                accessory
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }
}

extension Card where Accessory == EmptyView {
    init(title: String, info: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.info = info; self.accessory = EmptyView(); self.content = content()
    }
}

private struct StreamReport: View {
    let stream: AnalysisReport.Stream
    let thumbnail: NSImage?
    let duration: Double
    var trend: AnalysisModel.LiveTrend?
    var missing = false
    @State private var chart = "cinst"

    private var isVideo: Bool { stream.kind == "video" }
    private var isAudio: Bool { stream.kind == "audio" }

    var body: some View {
        let s = stream
        VStack(alignment: .leading, spacing: 16) {
            // Kopf: Vorschaubild, Format, Ziel, Zustand
            HStack(alignment: .center, spacing: 16) {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit)
                        .frame(width: 176)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .accessibilityLabel("Vorschaubild des Videostroms")
                } else {
                    Image(systemName: isVideo ? "film" : isAudio ? "waveform" : "text.alignleft")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 64, height: 64)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr(s.kindTitle)).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                    Text(tr(s.summary)).font(.system(size: 26, weight: .semibold, design: .rounded))
                    Text(tr(streamLine(s))).font(.callout.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                StatusPill(level: s.worstLevel, missing: missing)
            }
            .padding(16)
            .cardBackground()

            // Kennzahlen: live als Verlauf, sonst als Werte
            if let t = trend {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                    LiveChartTile(title: "Datenrate", unit: "Mbit/s", series: t.rate)
                    LiveChartTile(title: "Verluste", unit: "Pakete", series: t.lost, warnAbove: 0.5,
                                  info: "Fehlende RTP-Pakete je Abschnitt von 3 Sekunden, erkannt an Lücken in der Sequenznummer.")
                    if isVideo {
                        LiveChartTile(title: "Bildrate", unit: "fps", series: t.fps, format: "%.2f", tint: .purple)
                        LiveChartTile(title: "Cinst max.", unit: "Pakete", series: t.timing, tint: .teal,
                                      warnAbove: s.video?.limits["cmax_wide"].flatMap { $0 },
                                      info: "Höchster Stau im Modell-Netzpuffer nach ST 2110-21 je Abschnitt. Orange, wenn die Grenze für Wide überschritten wird.")
                    } else if isAudio {
                        LiveChartTile(title: "TS-DF max.", unit: "µs", series: t.timing, tint: .teal,
                                      info: "Größte Laufzeitschwankung der Audiopakete je Abschnitt. Der Empfänger muss mindestens so viel puffern.")
                    }
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                    StatTile(label: "Datenrate", value: String(format: "%.0f Mbit/s", locale: .current, s.rate_mbps ?? 0))
                    StatTile(label: "Verluste", value: s.lost.formatted(), note: lossNote)
                    if let v = s.video {
                        StatTile(label: "Bildrate", value: String(format: "%.3f", locale: .current, v.fps ?? 0), note: "\(v.frames.formatted()) Bilder")
                        StatTile(label: "ST 2110-21", value: senderClass(v.st2110_21_class),
                                 note: String(format: "Cmax %.0f, VRX %.0f", locale: .current, v.cinst.max, v.vrx.max),
                                 info: "Senderklasse nach ST 2110-21: Narrow ist sehr gleichmäßig, Wide erlaubt mehr Bursts.")
                    } else if let au = s.audio {
                        StatTile(label: "Paketzeit", value: String(format: "%g ms", locale: .current, au.ptime_ms ?? 0), note: String(au.channels) + (au.channels_from_sdp ? " Kanäle" : " Kanäle (geschätzt)"))
                        StatTile(label: "TS-DF max.", value: String(format: "%.0f µs", locale: .current, au.tsdf_us.max), note: "1-s-Fenster")
                    }
                }
            }

            // Hauptdiagramm: Auswahl hängt nur von der Art des Stroms ab und bleibt daher stehen
            if isVideo || isAudio {
                Card(title: "Verlauf", info: explanation) {
                    Picker("Diagramm", selection: $chart) {
                        ForEach(chartChoices, id: \.0) { Text(tr($0.1)).tag($0.0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                } content: {
                    MainChart(series: series, limits: limits, unit: unit)
                        .frame(height: trend == nil ? 260 : 200)
                }
                .onAppear { normalizeChart() }
                .onChange(of: stream.key) { _, _ in normalizeChart() }
            }

            HStack(alignment: .top, spacing: 16) {
                Card(title: "Befunde") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(s.findings, id: \.self) { FindingRow(finding: $0) }
                        if let anc = s.anc, !anc.did_sdid.isEmpty {
                            Text(tr("DID/SDID: " + anc.did_sdid.map { String(format: "%02X/%02X (%d)", locale: .current, $0.did, $0.sdid, $0.count) }.joined(separator: ", ")))
                                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
                Card(title: "Paketabstände", info: "Verteilung der Abstände zwischen aufeinanderfolgenden Paketen in Mikrosekunden.") {
                    IATHistogram(bins: s.iat_histogram).frame(height: 120)
                }
                .frame(width: 340)
            }
        }
    }

    private func normalizeChart() {
        if !chartChoices.contains(where: { $0.0 == chart }) { chart = chartChoices.first?.0 ?? "iat_us" }
    }

    private var lossNote: String? {
        let total = stream.packets + stream.lost
        guard total > 0 else { return nil }
        return String(format: "%.4f %% von %@", locale: .current, Double(stream.lost) / Double(total) * 100, total.formatted())
    }

    private var chartChoices: [(String, String)] {
        if isVideo {
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

/// Zustand eines Stroms als farbige Kapsel.
private struct StatusPill: View {
    let level: Int
    let missing: Bool

    var body: some View {
        let (text, color, icon): (String, Color, String) =
            missing ? ("Kein Empfang", .secondary, "pause.circle.fill")
            : level >= 2 ? ("Fehler", .red, "xmark.octagon.fill")
            : level == 1 ? ("Hinweise", .orange, "exclamationmark.triangle.fill")
            : ("In Ordnung", .green, "checkmark.circle.fill")
        Label(tr(text), systemImage: icon)
            .font(.callout.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(color.opacity(0.12), in: Capsule())
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
                            Text(tr(label)).font(.caption).foregroundStyle(.secondary)
                        }
                }
            }
            .chartXAxisLabel("Zeit im Mitschnitt (s)")
            .chartYAxisLabel(unit)
            .chartXAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(Color.primary.opacity(0.08)); AxisValueLabel().font(.caption.monospacedDigit()) } }
            .chartYAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(Color.primary.opacity(0.08)); AxisValueLabel().font(.caption.monospacedDigit()) } }
            .accessibilityLabel(tr("Diagramm \(unit) über die Zeit"))
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
                    GridRow { Text("Domain").foregroundStyle(.secondary); Text(tr("\(p.domain)")) }
                    GridRow { Text("Grandmaster").foregroundStyle(.secondary); Text(tr(p.grandmaster.isEmpty ? "–" : p.grandmaster)).monospacedDigit() }
                    GridRow { Text("Sendende Master").foregroundStyle(.secondary); Text(tr("\(p.masters)")).foregroundStyle(p.masters > 1 ? .red : .primary) }
                    GridRow { Text("Priorität 1 / 2, Klasse").foregroundStyle(.secondary); Text(tr("\(p.priority1) / \(p.priority2), Clock Class \(p.clock_class)")) }
                    GridRow { Text("Sync / Announce je s").foregroundStyle(.secondary); Text(tr(String(format: "%.2f / %.2f%@", locale: .current, p.sync_rate ?? 0, p.announce_rate ?? 0, p.two_step ? " (Two-Step)" : ""))).monospacedDigit() }
                    GridRow { Text("Delay-Req / -Resp").foregroundStyle(.secondary); Text(tr("\(p.delay_req) / \(p.delay_resp)")).monospacedDigit() }
                    GridRow { Text("UTC-Versatz").foregroundStyle(.secondary); Text(tr("\(p.utc_offset) s")) }
                }
                .font(.callout)
                .padding(16)
                .cardBackground()
            }
            Text("IGMP").font(.title3.weight(.medium))
            HStack(spacing: 4) {
                Text(tr(report.igmp.queries > 0 ? "Querier: \(report.igmp.querier) (\(report.igmp.queries) Abfragen, davon \(report.igmp.v3_queries) IGMPv3)" : "Kein IGMP-Querier gesehen"))
                    .font(.callout).foregroundStyle(report.igmp.queries > 0 ? .primary : .secondary)
                if report.igmp.queries == 0 {
                    InfoButton(text: "Ohne Querier kann der Switch Multicast nach einiger Zeit abschalten.")
                }
            }
            ForEach(report.igmp.groups, id: \.self) { g in
                Text(tr("\(g.group): \(g.joins) Beitritte, \(g.leaves) Austritte")).font(.callout.monospacedDigit())
            }
        }
    }
}

private func captureLine(_ c: AnalysisReport.Capture) -> String {
    var parts: [String] = [c.format, tr(c.packets.formatted() + " Pakete"),
                           String(format: "%.1f", locale: .current, c.duration_s) + " s",
                           tr("Zeitauflösung " + String(c.timestamp_resolution_ns) + " ns")]
    if c.software_capture { parts.append(tr("Software-Mitschnitt")) }
    return parts.joined(separator: ", ")
}

private func streamLine(_ s: AnalysisReport.Stream) -> String {
    var parts: [String] = [tr(s.source + " nach " + s.destination),
                           "SSRC " + String(format: "%08X", s.ssrc), "PT " + String(s.payload_type)]
    if s.sdp_matched { parts.append(tr("SDP zugeordnet")) }
    return parts.joined(separator: ", ")
}

private func senderClass(_ c: String) -> String {
    switch c {
    case "N": return "Narrow"
    case "W": return "Wide"
    case "nicht konform": return "außerhalb"
    default: return "–"
    }
}
