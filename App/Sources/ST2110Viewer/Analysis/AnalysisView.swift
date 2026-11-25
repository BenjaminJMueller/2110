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
        let live = a.isLive(entry)
        ScrollView {
            Group {
                if a.selectedStream == AnalysisModel.network {
                    NetworkReport(report: report)
                } else if let key = a.selectedStream, let s = report.streams.first(where: { $0.key == key }) {
                    StreamDetail(stream: s, thumbnail: entry.thumbnails[s.key],
                                 trend: live ? a.liveTrends[s.key] : nil,
                                 missing: live && a.liveMissing.contains(s.key))
                        .id(key)
                } else {
                    CaptureOverview(entry: entry, report: report, live: live)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 1040, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

private func levelColor(_ l: Int) -> Color { l >= 2 ? .red : l == 1 ? .orange : .green }

private func lossPercent(_ s: AnalysisReport.Stream) -> Double {
    let total = s.packets + s.lost
    return total > 0 ? Double(s.lost) / Double(total) * 100 : 0
}

private func kindShort(_ k: String) -> String {
    ["video": "Video", "audio": "Audio", "anc": "Zusatzdaten"][k] ?? "RTP"
}

private func kindIcon(_ k: String) -> String {
    ["video": "film", "audio": "waveform", "anc": "text.alignleft"][k] ?? "questionmark"
}

private func kindTint(_ k: String) -> Color {
    ["video": Color.blue, "audio": Color.pink, "anc": Color.teal][k] ?? .gray
}

/// Symbol in einer farbigen Kachel, wie in den Systemeinstellungen.
private struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .accessibilityHidden(true)
    }
}

// MARK: Übersicht eines Mitschnitts

private struct CaptureOverview: View {
    @Environment(AppModel.self) private var model
    let entry: AnalysisModel.Entry
    let report: AnalysisReport
    let live: Bool

    var body: some View {
        let a = model.analysis
        let c = report.capture
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        Text(tr(live ? a.liveName : entry.url.deletingPathExtension().lastPathComponent))
                            .font(.title.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                        if live { LiveBadge() }
                    }
                    HStack(spacing: 4) {
                        Text(tr(live ? "Abschnitt \(a.liveRounds), alle 3 s neu" : overviewLine(c)))
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                        InfoButton(text: live ? "Die App zeichnet den Empfang in Abschnitten von 3 Sekunden auf und prüft jeden sofort. Fehlt ein Strom in einem Abschnitt, bleibt sein letzter Stand stehen." : captureInfo(c))
                    }
                }
                Spacer()
                if live {
                    Button { a.stopLive() } label: { Label("Beenden", systemImage: "stop.fill") }
                        .controlButtonStyle(prominent: true)
                } else if entry.url.isFileURL && FileManager.default.fileExists(atPath: entry.url.path) {
                    Button { a.exportJSON(entry) } label: { Image(systemName: "square.and.arrow.up") }
                        .iconButtonStyle()
                        .help("Bericht als JSON exportieren")
                }
            }

            let problems = (c.findings ?? []).filter { $0.level >= 1 && !$0.text.hasPrefix("Software-Mitschnitt") }
            if !problems.isEmpty {
                VStack(alignment: .leading, spacing: 8) { ForEach(problems, id: \.self) { FindingRow(finding: $0) } }
            }

            VStack(spacing: 0) {
                ForEach(Array(report.orderedStreams.enumerated()), id: \.element.key) { i, s in
                    if i > 0 { Divider().padding(.leading, 60) }
                    OverviewRow(symbol: kindIcon(s.kind), tint: kindTint(s.kind), title: s.summary,
                                subtitle: kindShort(s.kind) + ", " + s.destination,
                                values: [(String(format: "%.0f", locale: .current, s.rate_mbps ?? 0), "Mbit/s"),
                                         (String(format: "%.2f %%", locale: .current, lossPercent(s)), "Verlust")],
                                level: s.worstLevel, missing: live && a.liveMissing.contains(s.key)) {
                        a.selectedStream = s.key
                    }
                }
                Divider().padding(.leading, 60)
                OverviewRow(symbol: "clock.arrow.2.circlepath", tint: .indigo, title: "PTP und IGMP",
                            subtitle: networkSummary(report), values: [], level: networkLevel(report), missing: false) {
                    a.selectedStream = AnalysisModel.network
                }
            }
            .cardBackground()
        }
    }
}

private struct LiveBadge: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.red)
                .symbolEffect(.pulse, options: .repeating)
            Text("Live").font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Color.red.opacity(0.12), in: Capsule())
    }
}

/// Zeile der Übersicht: anklickbar, mit Kennzahlen und Zustand.
private struct OverviewRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    let values: [(String, String)]
    let level: Int
    let missing: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                IconTile(symbol: symbol, tint: tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr(title)).font(.body.weight(.medium))
                    Text(tr(subtitle)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(v.0).font(.callout.weight(.semibold).monospacedDigit())
                        Text(tr(v.1)).font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(minWidth: 64, alignment: .trailing)
                }
                Circle().fill(missing ? Color.secondary.opacity(0.4) : levelColor(level)).frame(width: 8, height: 8)
                    .padding(.leading, 6)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .contentShape(Rectangle())
            .background(hover ? Color.primary.opacity(0.04) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(tr(title + ", " + subtitle))
    }
}

private func overviewLine(_ c: AnalysisReport.Capture) -> String {
    tr(String(format: "%.1f s", locale: .current, c.duration_s) + ", " + c.packets.formatted() + " Pakete")
}

private func captureInfo(_ c: AnalysisReport.Capture) -> String {
    var t = tr("Format \(c.format), Zeitauflösung \(c.timestamp_resolution_ns) ns.")
    if c.software_capture {
        t += " " + tr("Software-Mitschnitt: Die Zeitstempel stammen vom Betriebssystem. Cinst, VRX und Paketabstände sind daher Richtwerte.")
    }
    return t
}

private func networkSummary(_ r: AnalysisReport) -> String {
    let ptp = r.ptp.isEmpty ? tr("Kein PTP") : tr("PTP-Domain \(r.ptp.map { String($0.domain) }.joined(separator: ", "))")
    let igmp = r.igmp.queries > 0 ? tr("Querier vorhanden") : tr("kein Querier")
    return ptp + ", " + igmp
}

private func networkLevel(_ r: AnalysisReport) -> Int {
    if r.ptp.contains(where: { $0.masters > 1 }) { return 2 }
    return r.ptp.isEmpty || r.igmp.queries == 0 ? 1 : 0
}

// MARK: Ein Strom

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

/// Eine Kennzahl der Faktenleiste.
private struct Fact {
    let label: String
    let value: String
    var note: String?
    var info: String?
    var trend: LiveSeries?
    var warn = false
}

/// Kennzahlen in einer Leiste über die volle Breite, getrennt durch Linien.
private struct FactsBar: View {
    let facts: [Fact]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(facts.enumerated()), id: \.offset) { i, f in
                if i > 0 { Divider().padding(.vertical, 12) }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(tr(f.label)).font(.caption).foregroundStyle(.secondary)
                        if let info = f.info { InfoButton(text: info) }
                    }
                    Text(tr(f.value))
                        .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(f.warn ? Color.orange : Color.primary)
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .contentTransition(.numericText())
                    if let t = f.trend, t.values.count > 1 {
                        Sparkline(values: t.values, color: f.warn ? .orange : .accentColor).frame(height: 22)
                    } else {
                        Text(tr(f.note ?? " ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .cardBackground()
    }
}

/// Messgröße mit eigenem Verlauf; die Reiter wählen das große Diagramm.
private struct Metric: Identifiable {
    let id: String
    let title: String
    let info: String
    let value: String
    let series: AnalysisReport.Series?
    let unit: String
    var limits: [(String, Double)] = []
}

private struct StreamDetail: View {
    let stream: AnalysisReport.Stream
    let thumbnail: NSImage?
    var trend: AnalysisModel.LiveTrend?
    var missing = false
    @State private var selected = ""

    var body: some View {
        let s = stream
        let ms = metrics
        let current = ms.first { $0.id == selected } ?? ms.first
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 14) {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 96, height: 54)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .accessibilityLabel("Vorschaubild des Videostroms")
                } else {
                    IconTile(symbol: kindIcon(s.kind), tint: kindTint(s.kind), size: 44)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr(s.summary)).font(.title.weight(.semibold))
                    HStack(spacing: 4) {
                        Text(tr(kindShort(s.kind) + ", " + s.destination)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        InfoButton(text: tr(s.kindTitle) + ". " + streamLine(s) + ".")
                    }
                }
                Spacer()
                StatusPill(level: s.worstLevel, missing: missing)
            }

            FactsBar(facts: facts)

            if !ms.isEmpty, let current {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        ForEach(Array(ms.enumerated()), id: \.element.id) { i, m in
                            if i > 0 { Divider().padding(.vertical, 10) }
                            MetricTab(metric: m, selected: m.id == current.id) { selected = m.id }
                        }
                    }
                    Divider()
                    Group {
                        if current.id == "iat_us" {
                            IATHistogram(bins: s.iat_histogram)
                        } else {
                            MainChart(series: current.series, limits: current.limits, unit: current.unit)
                        }
                    }
                    .frame(height: 240)
                    .padding(16)
                }
                .cardBackground()
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Befunde").font(.headline)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(s.findings, id: \.self) { FindingRow(finding: $0) }
                    if let anc = s.anc, !anc.did_sdid.isEmpty {
                        Text(tr("DID/SDID: " + anc.did_sdid.map { String(format: "%02X/%02X (%d)", locale: .current, $0.did, $0.sdid, $0.count) }.joined(separator: ", ")))
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardBackground()
            }
        }
    }

    private var facts: [Fact] {
        let s = stream
        var f: [Fact] = [
            Fact(label: "Datenrate", value: String(format: "%.0f Mbit/s", locale: .current, s.rate_mbps ?? 0), trend: trend?.rate),
            Fact(label: "Verluste", value: String(format: "%.2f %%", locale: .current, lossPercent(s)),
                 note: tr("\(s.lost.formatted()) von \((s.packets + s.lost).formatted()) Paketen"),
                 info: "Fehlende RTP-Pakete, erkannt an Lücken in der Sequenznummer.", trend: trend?.lost, warn: s.lost > 0),
        ]
        if let v = s.video {
            f.append(Fact(label: "Bildrate", value: String(format: "%.2f", locale: .current, v.fps ?? 0),
                          note: tr("\(v.frames.formatted()) Bilder"), trend: trend?.fps))
            f.append(Fact(label: "Senderklasse", value: senderClass(v.st2110_21_class),
                          note: "ST 2110-21",
                          info: "Wie gleichmäßig der Sender seine Pakete verteilt. Narrow: sehr gleichmäßig, für alle Empfänger geeignet. Wide: mehr Bursts, nur für Empfänger mit größerem Puffer.",
                          warn: v.st2110_21_class == "nicht konform"))
        } else if let au = s.audio {
            f.append(Fact(label: "Paketzeit", value: String(format: "%g ms", locale: .current, au.ptime_ms ?? 0),
                          note: tr("\(au.samples_per_packet) Samples je Paket")))
            f.append(Fact(label: "Kanäle", value: String(au.channels),
                          note: au.channels_from_sdp ? "aus SDP" : "geschätzt"))
        } else {
            f.append(Fact(label: "Pakete", value: s.packets.formatted()))
        }
        return f
    }

    private var metrics: [Metric] {
        let s = stream
        if let v = s.video {
            return [
                Metric(id: "cinst", title: "Cinst", info: "Wie viele Pakete sich im Modell-Netzpuffer stauen, je Bild (ST 2110-21). Unter der Linie „Narrow“ ist der Sender so gleichmäßig, wie es empfindliche Empfänger erwarten.",
                       value: String(format: "max. %.0f", locale: .current, v.cinst.max), series: v.series["cinst"], unit: "Pakete",
                       limits: [("Narrow", v.limits["cmax_narrow"].flatMap { $0 } ?? 0), ("Wide", v.limits["cmax_wide"].flatMap { $0 } ?? 0)]),
                Metric(id: "vrx", title: "VRX", info: "Füllstand eines gedachten Empfängerpuffers, der ab dem ersten Paket eines Bildes gleichmäßig liest. Hohe Werte bedeuten Bursts.",
                       value: String(format: "max. %.0f", locale: .current, v.vrx.max), series: v.series["vrx"], unit: "Pakete",
                       limits: [("Narrow", v.limits["vrx_narrow"].flatMap { $0 } ?? 0)]),
                Metric(id: "packets_per_frame", title: "Pakete je Bild", info: "Schwankungen deuten auf Verluste oder Formatwechsel hin.",
                       value: String(format: "%.0f", locale: .current, v.packets_per_frame.avg), series: v.series["packets_per_frame"], unit: "Pakete"),
                Metric(id: "rtp_latency_ms", title: "RTP-Latenz", info: "Abstand zwischen Ankunft des ersten Pakets und der Bildzeit im RTP-Zeitstempel. Aussagekräftig, wenn der aufzeichnende Rechner PTP-synchron war.",
                       value: String(format: "%.1f ms", locale: .current, v.rtp_latency_ms.avg), series: v.series["rtp_latency_ms"], unit: "ms"),
                Metric(id: "iat_us", title: "Paketabstand", info: "Abstand zwischen aufeinanderfolgenden Paketen. Das Diagramm zeigt die Verteilung in Mikrosekunden.",
                       value: String(format: "%.1f µs", locale: .current, s.iat_us.avg), series: v.series["iat_us"], unit: "µs"),
            ]
        }
        if let au = s.audio {
            return [
                Metric(id: "tsdf_us", title: "TS-DF", info: "Timestamped Delay Factor: Schwankung der Laufzeit der Audiopakete gegenüber ihren Zeitstempeln. Der Empfänger muss mindestens so viel puffern.",
                       value: String(format: "max. %.0f µs", locale: .current, au.tsdf_us.max), series: au.series["tsdf_us"], unit: "µs"),
                Metric(id: "iat_us", title: "Paketabstand", info: "Abstand zwischen aufeinanderfolgenden Paketen. Das Diagramm zeigt die Verteilung in Mikrosekunden.",
                       value: String(format: "%.1f µs", locale: .current, s.iat_us.avg), series: au.series["iat_us"], unit: "µs"),
            ]
        }
        return []
    }
}

/// Reiter einer Messgröße: Name, Wert, kleiner Verlauf.
private struct MetricTab: View {
    let metric: Metric
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(tr(metric.title)).font(.caption.weight(.medium))
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    InfoButton(text: metric.info)
                }
                Text(tr(metric.value)).font(.system(size: 16, weight: .semibold, design: .rounded).monospacedDigit())
                    .lineLimit(1).minimumScaleFactor(0.7)
                if let s = metric.series {
                    Sparkline(values: s.v.compactMap { $0 }, color: selected ? .accentColor : .secondary).frame(height: 20)
                } else {
                    Color.clear.frame(height: 20)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.08) : Color.clear)
            .overlay(alignment: .bottom) {
                if selected { Rectangle().fill(Color.accentColor).frame(height: 2) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Kleiner Verlauf ohne Achsen.
private struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        let pts = Self.downsample(values, to: 120)
        let lo = pts.min() ?? 0, hi = pts.max() ?? 1
        Chart {
            ForEach(Array(pts.enumerated()), id: \.offset) { i, v in
                LineMark(x: .value("t", i), y: .value("v", v))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.2))
                    .interpolationMethod(.monotone)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: lo...(hi > lo ? hi : lo + 1))
        .clipped()
        .accessibilityHidden(true)
    }

    static func downsample(_ v: [Double], to n: Int) -> [Double] {
        guard v.count > n else { return v }
        let step = Double(v.count) / Double(n)
        return (0..<n).map { i in
            let a = Int(Double(i) * step), b = min(v.count, Int(Double(i + 1) * step))
            return v[a..<max(b, a + 1)].max() ?? 0
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
            HStack(spacing: 14) {
                IconTile(symbol: "clock.arrow.2.circlepath", tint: .indigo, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("PTP und IGMP").font(.title.weight(.semibold))
                    Text(tr(networkSummary(report))).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                StatusPill(level: networkLevel(report), missing: false)
            }

            section("PTP", info: "Precision Time Protocol: der Grandmaster gibt allen Geräten die Zeit vor. Es sollte genau einen sendenden Master je Domain geben.") {
                if report.ptp.isEmpty {
                    Text("Keine PTP-Nachrichten im Mitschnitt.").foregroundStyle(.secondary)
                }
                ForEach(report.ptp) { p in
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 7) {
                        row("Domain", "\(p.domain)")
                        row("Grandmaster", p.grandmaster.isEmpty ? "–" : p.grandmaster)
                        row("Sendende Master", "\(p.masters)", warn: p.masters > 1)
                        row("Priorität 1 / 2", "\(p.priority1) / \(p.priority2)")
                        row("Clock Class", "\(p.clock_class)")
                        row("Sync / Announce je s", String(format: "%.2f / %.2f", locale: .current, p.sync_rate ?? 0, p.announce_rate ?? 0) + (p.two_step ? " (Two-Step)" : ""))
                        row("Delay-Req / -Resp", "\(p.delay_req) / \(p.delay_resp)")
                        row("UTC-Versatz", "\(p.utc_offset) s")
                    }
                }
            }

            section("IGMP", info: "Über IGMP melden Empfänger, welche Multicast-Gruppen sie wollen. Ohne Querier kann der Switch Multicast nach einiger Zeit abschalten.") {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 7) {
                    row("Querier", report.igmp.queries > 0 ? report.igmp.querier : "keiner gesehen", warn: report.igmp.queries == 0)
                    if report.igmp.queries > 0 {
                        row("Abfragen", "\(report.igmp.queries), davon \(report.igmp.v3_queries) IGMPv3")
                    }
                    ForEach(report.igmp.groups, id: \.self) { g in
                        row(g.group, "\(g.joins) Beitritte, \(g.leaves) Austritte")
                    }
                }
            }
        }
    }

    private func section<C: View>(_ title: String, info: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                Text(tr(title)).font(.headline)
                InfoButton(text: info)
            }
            VStack(alignment: .leading, spacing: 14) { content() }
                .font(.callout)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardBackground()
        }
    }

    private func row(_ k: String, _ v: String, warn: Bool = false) -> some View {
        GridRow {
            Text(tr(k)).foregroundStyle(.secondary)
            Text(tr(v)).monospacedDigit().foregroundStyle(warn ? Color.orange : Color.primary).textSelection(.enabled)
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
