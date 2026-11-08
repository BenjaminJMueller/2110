import AppKit
import Charts
import SwiftUI

/// Messwerte über die Zeit für die Live-Diagramme (letzte zwei Minuten, ein Wert je Sekunde).
struct LiveSeries: Equatable {
    private(set) var values: [Double] = []
    static let capacity = 120

    mutating func append(_ v: Double) {
        values.append(v.isFinite ? v : 0)
        if values.count > Self.capacity { values.removeFirst(values.count - Self.capacity) }
    }

    mutating func reset() { values.removeAll() }

    var last: Double? { values.last }
    var maxValue: Double { values.max() ?? 0 }
    var average: Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }
}

/// Kompakte Kachel: aktueller Wert groß, darunter der Verlauf als Fläche.
struct LiveChartTile: View {
    let title: String
    let unit: String
    let series: LiveSeries
    var format: String = "%.0f"
    var tint: Color = .accentColor
    /// Ab diesem Wert wird der Verlauf orange (z. B. Paketverlust).
    var warnAbove: Double?
    var info: String?

    private var warn: Bool {
        guard let w = warnAbove, let l = series.last else { return false }
        return l > w
    }

    var body: some View {
        let color = warn ? Color.orange : tint
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(tr(title)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let info { InfoButton(text: info) }
                Spacer(minLength: 0)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(series.last.map { String(format: format, locale: .current, $0) } ?? "–")
                    .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                    .foregroundStyle(warn ? Color.orange : Color.primary)
                Text(tr(unit)).font(.caption).foregroundStyle(.secondary)
            }
            Chart {
                ForEach(Array(series.values.enumerated()), id: \.offset) { i, v in
                    AreaMark(x: .value("t", i), y: .value("v", v))
                        .foregroundStyle(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.02)],
                                                        startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("t", i), y: .value("v", v))
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.monotone)
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartXScale(domain: 0...max(LiveSeries.capacity - 1, series.values.count - 1))
            .chartYScale(domain: yDomain)
            .frame(height: 44)
            .clipped()
            .accessibilityHidden(true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tr(title))
        .accessibilityValue(series.last.map { String(format: format, locale: .current, $0) + " " + tr(unit) } ?? "–")
    }

    private var minimumScale: Double { warnAbove.map { max($0 * 2, 1) } ?? 1 }

    /// Auch negative Werte (z. B. Laufzeit) bleiben im Kasten.
    private var yDomain: ClosedRange<Double> {
        let lo = min(0, series.values.min() ?? 0)
        let hi = max(series.maxValue, 0)
        let span = max(hi - lo, minimumScale)
        return (lo < 0 ? lo - span * 0.1 : 0)...(lo + span * 1.15)
    }
}

/// Kleines „i“ neben einer Überschrift; die Erklärung erscheint als Popover.
struct InfoButton: View {
    let text: String
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "info.circle").font(.caption).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(tr(text))
        .accessibilityLabel(tr("Erklärung"))
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            Text(tr(text))
                .font(.callout)
                .lineLimit(nil)
                .frame(width: Self.width, height: Self.height(for: tr(text)), alignment: .topLeading)
                .padding(14)
        }
    }

    private static let width: CGFloat = 300

    /// Popover messen ihren Inhalt unter macOS nicht zuverlässig, längere Texte
    /// würden mit „…“ abgeschnitten. Daher die Höhe vorab ausrechnen.
    private static func height(for text: String) -> CGFloat {
        let font = NSFont.preferredFont(forTextStyle: .callout)
        let r = (text as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                                 options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                 attributes: [.font: font])
        return ceil(r.height) + 4
    }
}
