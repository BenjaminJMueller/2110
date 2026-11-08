import AppKit
import SwiftUI

/// Erklärung beim ersten Start und jederzeit über „?“: wie ST 2110 funktioniert
/// und wie 2110 Viewer damit arbeitet. Diagramme sind selbst gezeichnet; Bewegung
/// zeigt den Paketfluss und entfällt bei „Bewegung reduzieren“.
struct ExplainerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    static let pageCount = 6

    var body: some View {
        let page = model.explainerPage
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Schließen") { finish() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)

            Group {
                switch page {
                case 0: WelcomePage()
                case 1: EssencesPage()
                case 2: MulticastPage()
                case 3: PTPPage()
                case 4: NMOSPage()
                default: ReadyPage(start: { finish() })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 40)
            .id(page)
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 24)), removal: .opacity))

            HStack(spacing: 12) {
                HStack(spacing: 7) {
                    ForEach(0..<Self.pageCount, id: \.self) { i in
                        Capsule()
                            .fill(i == page ? Color.accentColor : Color.primary.opacity(0.15))
                            .frame(width: i == page ? 22 : 8, height: 8)
                            .contentShape(Rectangle())
                            .onTapGesture { go(i) }
                            .accessibilityLabel(tr("Seite \(i + 1) von \(Self.pageCount)"))
                            .accessibilityAddTraits(i == page ? .isSelected : [])
                    }
                }
                Spacer()
                if page > 0 && page < Self.pageCount - 1 {
                    Button("Zurück") { go(page - 1) }
                        .keyboardShortcut(.leftArrow, modifiers: [])
                        .controlButtonStyle()
                        .controlSize(.large)
                }
                if page < Self.pageCount - 1 {
                    Button { go(page + 1) } label: {
                        Text(page == 0 ? "Los geht’s" : "Weiter").frame(minWidth: 120)
                    }
                    .keyboardShortcut(.defaultAction)
                    .controlButtonStyle(prominent: true)
                    .controlSize(.large)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
        }
        .frame(width: 880, height: 640)
    }

    private func go(_ p: Int) {
        withAnimation(.smooth(duration: 0.35)) { model.explainerPage = max(0, min(Self.pageCount - 1, p)) }
    }

    private func finish() {
        model.finishOnboarding()
        dismiss()
    }
}

// MARK: - Bausteine

/// Überschrift und ein Satz, zentriert.
private struct Headline: View {
    let title: String
    let lead: String
    var body: some View {
        VStack(spacing: 10) {
            Text(tr(title)).font(.system(size: 34, weight: .bold)).multilineTextAlignment(.center)
            Text(tr(lead)).font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 560).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Kurzer Hinweis als Kapsel unter der Grafik.
private struct Chip: View {
    let icon: String
    let text: String
    var body: some View {
        Label(tr(text), systemImage: icon)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Color(nsColor: .quaternarySystemFill), in: Capsule())
    }
}

private struct Chips: View {
    let items: [(String, String)]
    var body: some View {
        HStack(spacing: 10) { ForEach(Array(items.enumerated()), id: \.offset) { _, it in Chip(icon: it.0, text: it.1) } }
    }
}

/// Große Kachel mit Symbol, Titel und einer Zeile.
private struct Tile: View {
    let icon: String
    let title: String
    let text: String
    var tint: Color = .accentColor
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(height: 44)
            Text(tr(title)).font(.headline)
            Text(tr(text)).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.vertical, 24).padding(.horizontal, 16)
        .cardBackground(cornerRadius: 18)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Seiten

private struct WelcomePage: View {
    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 0)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 112, height: 112)
                .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
                .accessibilityHidden(true)
            Headline(title: "Willkommen",
                     lead: "2110 Viewer empfängt, sendet und analysiert ST 2110 auf dem Mac. Entstanden für die Lehre.")
            HStack(spacing: 16) {
                Tile(icon: "play.rectangle.fill", title: "Empfangen", text: "Quellen im Netz ansehen und abhören")
                Tile(icon: "dot.radiowaves.up.forward", title: "Senden", text: "Testbild, Video oder Kamera ins Netz senden")
                Tile(icon: "waveform.path.ecg.rectangle.fill", title: "Analysieren", text: "Mitschnitte und Empfang prüfen")
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 680)
            Spacer(minLength: 0)
        }
    }
}

private struct EssencesPage: View {
    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)
            Headline(title: "Getrennte Ströme",
                     lead: "Ein SDI-Signal wird in Video, Audio und Zusatzdaten aufgeteilt. Jeder Strom hat eine eigene Zieladresse, meist eine eigene Multicast-Gruppe.")
            FlowDiagram(nodes: [
                .init(id: "sdi", title: "Kamera", subtitle: "SDI", icon: "video", x: 0.08, y: 0.5),
                .init(id: "conv", title: "Converter", subtitle: "SDI zu IP", icon: "arrow.left.arrow.right.square", x: 0.4, y: 0.5),
                .init(id: "v", title: "Video", subtitle: "ST 2110-20", icon: "film", x: 0.86, y: 0.14),
                .init(id: "a", title: "Audio", subtitle: "ST 2110-30", icon: "waveform", x: 0.86, y: 0.5),
                .init(id: "d", title: "Daten", subtitle: "ST 2110-40", icon: "text.alignleft", x: 0.86, y: 0.86),
            ], links: [
                .init(from: "sdi", to: "conv", style: .cable, density: 0),
                .init(from: "conv", to: "v", style: .accent, density: 12),
                .init(from: "conv", to: "a", style: .normal, density: 4),
                .init(from: "conv", to: "d", style: .normal, density: 1),
            ])
            .frame(height: 260)
            Chips(items: [("speedometer", "Video unkomprimiert, 1 bis 2,6 Gbit/s je HD-Strom"), ("cable.connector", "Mehr als Gigabit nötig, üblich ist 10 GbE")])
            Spacer(minLength: 0)
        }
    }
}

private struct MulticastPage: View {
    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)
            Headline(title: "Multicast",
                     lead: "Ein Sender, beliebig viele Empfänger. Empfänger melden sich per IGMP für einen Strom an; mit IGMP-Snooping leitet der Switch ihn nur dorthin weiter.")
            FlowDiagram(nodes: [
                .init(id: "s", title: "Sender", subtitle: "Multicast", icon: "dot.radiowaves.up.forward", x: 0.08, y: 0.5),
                .init(id: "sw", title: "Switch", subtitle: "IGMP", icon: "rectangle.connected.to.line.below", x: 0.42, y: 0.5),
                .init(id: "r1", title: "Monitor", subtitle: "angemeldet", icon: "display", x: 0.86, y: 0.14),
                .init(id: "r2", title: "2110 Viewer", subtitle: "angemeldet", icon: "laptopcomputer", x: 0.86, y: 0.5),
                .init(id: "r3", title: "Recorder", subtitle: "nicht angemeldet", icon: "externaldrive", x: 0.86, y: 0.86),
            ], links: [
                .init(from: "s", to: "sw", style: .accent, density: 8),
                .init(from: "sw", to: "r1", style: .accent, density: 8),
                .init(from: "sw", to: "r2", style: .accent, density: 8),
                .init(from: "sw", to: "r3", style: .idle, density: 0),
            ])
            .frame(height: 260)
            Chips(items: [("questionmark.circle", "Bild bricht nach Minuten ab? IGMP-Querier am Switch prüfen")])
            Spacer(minLength: 0)
        }
    }
}

private struct PTPPage: View {
    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            Headline(title: "PTP",
                     lead: "Alle Geräte richten ihre Uhr nach einem Grandmaster. Daraus entstehen die RTP-Zeitstempel, über die Bild und Ton synchron bleiben.")
            FlowDiagram(nodes: [
                .init(id: "gm", title: "Grandmaster", subtitle: "PTP", icon: "clock", x: 0.5, y: 0.12),
                .init(id: "c", title: "Converter", subtitle: "Follower", icon: "arrow.left.arrow.right.square", x: 0.16, y: 0.84),
                .init(id: "sw", title: "Switch", subtitle: "", icon: "rectangle.connected.to.line.below", x: 0.5, y: 0.84),
                .init(id: "m", title: "2110 Viewer", subtitle: "Follower", icon: "laptopcomputer", x: 0.84, y: 0.84),
            ], links: [
                .init(from: "gm", to: "c", style: .clock, density: 2),
                .init(from: "gm", to: "sw", style: .clock, density: 2),
                .init(from: "gm", to: "m", style: .clock, density: 2),
            ])
            .frame(height: 180)
            TimestampStrip()
                .frame(height: 86)
                .accessibilityLabel("Zeitachse: Videobilder alle 20 Millisekunden und Audiopakete jede Millisekunde tragen Zeitstempel derselben Uhr")
            Chips(items: [("ear", "2110 Viewer ist nur Follower, nie Master")])
            Spacer(minLength: 0)
        }
    }
}

private struct NMOSPage: View {
    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)
            Headline(title: "NMOS",
                     lead: "Über NMOS IS-04 machen Geräte ihre Ströme bekannt, per Registry oder direkt per mDNS. 2110 Viewer listet sie links unter „Im Netzwerk“.")
            FlowDiagram(nodes: [
                .init(id: "c", title: "Converter", subtitle: "„SDI 1“", icon: "arrow.left.arrow.right.square", x: 0.16, y: 0.5),
                .init(id: "e", title: "2110 Viewer", subtitle: "zeigt die Quelle an", icon: "laptopcomputer", x: 0.84, y: 0.5),
            ], links: [
                .init(from: "c", to: "e", style: .accent, density: 3, label: "Ich sende „SDI 1“"),
            ])
            .frame(height: 180)
            Chips(items: [("plus.circle", "Gerät per IP-Adresse hinzufügen"), ("doc", "SDP-Datei ins Fenster ziehen")])
            Spacer(minLength: 0)
        }
    }
}

private struct ReadyPage: View {
    let start: () -> Void
    var body: some View {
        VStack(spacing: 26) {
            Spacer(minLength: 0)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Headline(title: "Alles bereit",
                     lead: "Fragt macOS, ob die App das lokale Netzwerk nutzen darf, bitte „Erlauben“ wählen. Ohne diese Erlaubnis findet sie keine Geräte und empfängt kein Bild.")
            HStack(spacing: 16) {
                AllowTile()
                Tile(icon: "hand.raised.fill", title: "Ohne Erlaubnis", text: "Keine Geräte, kein Bild, kein Ton", tint: .orange)
                Tile(icon: "gearshape.fill", title: "Später ändern", text: "Systemeinstellungen › Datenschutz & Sicherheit › Lokales Netzwerk", tint: .gray)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 700)
            VStack(spacing: 10) {
                Button { start() } label: { Text("Los geht’s").frame(minWidth: 180) }
                    .keyboardShortcut(.defaultAction)
                    .controlButtonStyle(prominent: true)
                    .controlSize(.large)
                Button("Datenschutz-Einstellungen öffnen") {
                    if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
                        NSWorkspace.shared.open(u)
                    }
                }
                .buttonStyle(.link)
                .font(.callout)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Kachel mit nachgebildeten macOS-Knöpfen; „Erlauben“ ist hervorgehoben.
private struct AllowTile: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                Text("Nicht erlauben")
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                Text("Erlauben")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.accentColor, in: Capsule())
                    .shadow(color: Color.accentColor.opacity(pulse ? 0.6 : 0), radius: pulse ? 8 : 0)
                    .scaleEffect(pulse ? 1.06 : 1)
            }
            .lineLimit(1)
            .fixedSize()
            .frame(height: 44)
            Text("Erlauben").font(.headline)
            Text("Im Dialog von macOS auf „Erlauben“ klicken").font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.vertical, 24).padding(.horizontal, 16)
        .cardBackground(cornerRadius: 18)
        .accessibilityElement(children: .combine)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

// MARK: - Diagramm

struct FlowDiagram: View {
    struct Node: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let icon: String
        let x: CGFloat
        let y: CGFloat
    }
    struct Link: Identifiable {
        enum Style { case accent, normal, idle, cable, clock }
        let from: String
        let to: String
        let style: Style
        let density: Int
        var label: String? = nil
        var id: String { from + to }
    }

    let nodes: [Node]
    let links: [Link]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { tl in
                    Canvas { ctx, _ in
                        let t = tl.date.timeIntervalSinceReferenceDate
                        for l in links {
                            guard let a = pos(l.from, size), let b = pos(l.to, size) else { continue }
                            var path = Path()
                            path.move(to: a)
                            let mid = CGPoint(x: (a.x + b.x) / 2, y: a.y)
                            let mid2 = CGPoint(x: (a.x + b.x) / 2, y: b.y)
                            path.addCurve(to: b, control1: mid, control2: mid2)
                            let color: Color = l.style == .accent ? .accentColor : .primary.opacity(l.style == .idle ? 0.15 : 0.35)
                            let dash: [CGFloat] = l.style == .idle ? [3, 5] : l.style == .clock ? [6, 4] : []
                            ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: l.style == .accent ? 2.5 : l.style == .cable ? 4 : 1.5, lineCap: .round, dash: dash))
                            guard l.density > 0 else { continue }
                            for i in 0..<l.density {
                                let phase = reduceMotion ? Double(i) / Double(l.density) : (t * 0.35 + Double(i) / Double(l.density)).truncatingRemainder(dividingBy: 1)
                                let p = point(on: a, mid, mid2, b, CGFloat(phase))
                                let r: CGFloat = l.style == .accent ? 3.5 : 2.5
                                ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                                         with: .color(l.style == .accent ? .accentColor : .primary.opacity(0.55)))
                            }
                        }
                    }
                }
                ForEach(links.filter { $0.label != nil }) { l in
                    if let a = pos(l.from, size), let b = pos(l.to, size) {
                        Text(tr(l.label!)).font(.callout).foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .position(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 - 22)
                    }
                }
                ForEach(nodes) { n in
                    NodeView(node: n).position(x: n.x * size.width, y: n.y * size.height)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr(accessibilityText))
    }

    private var accessibilityText: String {
        "Schema: " + links.compactMap { l in
            guard let a = nodes.first(where: { $0.id == l.from }), let b = nodes.first(where: { $0.id == l.to }) else { return nil }
            return "\(a.title) zu \(b.title)\(l.style == .idle ? " (keine Verbindung)" : "")"
        }.joined(separator: ", ")
    }

    private func pos(_ id: String, _ s: CGSize) -> CGPoint? {
        guard let n = nodes.first(where: { $0.id == id }) else { return nil }
        return CGPoint(x: n.x * s.width, y: n.y * s.height)
    }

    private func point(on p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ t: CGFloat) -> CGPoint {
        let u = 1 - t
        let x = u * u * u * p0.x + 3 * u * u * t * p1.x + 3 * u * t * t * p2.x + t * t * t * p3.x
        let y = u * u * u * p0.y + 3 * u * u * t * p1.y + 3 * u * t * t * p2.y + t * t * t * p3.y
        return CGPoint(x: x, y: y)
    }
}

private struct NodeView: View {
    let node: FlowDiagram.Node
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: node.icon).font(.title3).foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(tr(node.title)).font(.callout.weight(.medium))
                if !node.subtitle.isEmpty { Text(tr(node.subtitle)).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        .fixedSize()
    }
}

/// Zeitachse: Videobilder (20 ms bei 50p) und Audiopakete (1 ms) mit
/// Zeitstempeln derselben Uhr; der Marker zeigt, was zusammengehört.
private struct TimestampStrip: View {
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, rowH: CGFloat = 26
            let msPx = w / 100.0  // 100 ms sichtbar
            ctx.draw(Text("Video").font(.caption).foregroundStyle(.secondary), at: CGPoint(x: 0, y: 10), anchor: .leading)
            ctx.draw(Text("Audio").font(.caption).foregroundStyle(.secondary), at: CGPoint(x: 0, y: 10 + rowH + 8), anchor: .leading)
            let x0: CGFloat = 56
            for f in 0..<5 {
                let r = CGRect(x: x0 + CGFloat(f) * 20 * msPx * 0.9, y: 0, width: 20 * msPx * 0.9 - 4, height: rowH - 6)
                ctx.fill(Path(roundedRect: r, cornerRadius: 4), with: .color(f == 2 ? .accentColor : .primary.opacity(0.12)))
            }
            for p in 0..<90 {
                let x = x0 + CGFloat(p) * msPx * 0.9
                let r = CGRect(x: x, y: rowH + 8, width: max(1, msPx * 0.9 - 1.5), height: rowH - 6)
                let inFrame = p >= 40 && p < 60
                ctx.fill(Path(r), with: .color(inFrame ? .accentColor.opacity(0.7) : .primary.opacity(0.18)))
            }
            let mx = x0 + 40 * msPx * 0.9
            var line = Path()
            line.move(to: CGPoint(x: mx, y: -2))
            line.addLine(to: CGPoint(x: mx, y: 2 * rowH + 6))
            ctx.stroke(line, with: .color(.primary.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            ctx.draw(Text("gleicher Zeitstempel, gemeinsame Wiedergabe").font(.caption).foregroundStyle(.secondary),
                     at: CGPoint(x: mx + 6, y: 2 * rowH + 20), anchor: .leading)
        }
    }
}
