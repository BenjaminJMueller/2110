import SwiftUI

/// Erklärung beim ersten Start und jederzeit über „?“: wie ST 2110 funktioniert
/// und wie 2110 Viewer damit arbeitet. Diagramme sind selbst gezeichnet; Bewegung
/// zeigt den Paketfluss und entfällt bei „Bewegung reduzieren“.
struct ExplainerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    static let pageCount = 5

    var body: some View {
        @Bindable var model = model
        let page = model.explainerPage
        VStack(spacing: 0) {
            HStack {
                Text("So funktioniert ST 2110").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Schließen") { finish() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)

            Group {
                switch page {
                case 0: EssencesPage()
                case 1: MulticastPage()
                case 2: PTPPage()
                case 3: NMOSPage()
                default: StartPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 32)
            .padding(.vertical, 16)
            .id(page)
            .transition(.opacity)

            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    ForEach(0..<Self.pageCount, id: \.self) { i in
                        Capsule()
                            .fill(i == page ? Color.accentColor : Color.primary.opacity(0.15))
                            .frame(width: i == page ? 20 : 8, height: 8)
                            .onTapGesture { go(i) }
                            .accessibilityLabel("Seite \(i + 1) von \(Self.pageCount)")
                            .accessibilityAddTraits(i == page ? .isSelected : [])
                    }
                }
                Spacer()
                if page > 0 {
                    Button("Zurück") { go(page - 1) }
                        .keyboardShortcut(.leftArrow, modifiers: [])
                }
                if page == Self.pageCount - 1 {
                    Button("Fertig") { finish() }
                        .keyboardShortcut(.defaultAction)
                        .controlButtonStyle(prominent: true)
                } else {
                    Button("Weiter") { go(page + 1) }
                        .keyboardShortcut(.rightArrow, modifiers: [])
                        .controlButtonStyle(prominent: true)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(.bar)
        }
        .frame(width: 860, height: 620)
    }

    private func go(_ p: Int) {
        withAnimation(.easeOut(duration: 0.2)) { model.explainerPage = max(0, min(Self.pageCount - 1, p)) }
    }

    private func finish() {
        model.settings.onboardingDone = true
        dismiss()
    }
}

// MARK: - Seiten

private struct PageText: View {
    let title: String
    let lead: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 28, weight: .semibold))
            Text(lead).font(.title3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 680, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct Bullet: View {
    let icon: String
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18).accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }
}

private struct EssencesPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageText(title: "Ein Signal, drei Essenzen",
                     lead: "SDI trägt Bild, Ton und Zusatzdaten in einem Kabel. ST 2110 trennt sie in eigene Netzwerkströme, die Essenzen. Jede Essenz hat eine eigene Multicast-Adresse.")
            FlowDiagram(nodes: [
                .init(id: "sdi", title: "Kamera", subtitle: "SDI 1080p50", icon: "video", x: 0.08, y: 0.5),
                .init(id: "conv", title: "2110 IP Converter", subtitle: "wandelt SDI in IP", icon: "arrow.left.arrow.right.square", x: 0.38, y: 0.5),
                .init(id: "v", title: "Video", subtitle: "ST 2110-20 · ≈ 2,2 Gbit/s", icon: "film", x: 0.84, y: 0.16),
                .init(id: "a", title: "Audio", subtitle: "ST 2110-30 · 16 Kanäle", icon: "waveform", x: 0.84, y: 0.5),
                .init(id: "d", title: "Daten", subtitle: "ST 2110-40 · Timecode", icon: "text.alignleft", x: 0.84, y: 0.84),
            ], links: [
                .init(from: "sdi", to: "conv", style: .cable, density: 0),
                .init(from: "conv", to: "v", style: .accent, density: 12),
                .init(from: "conv", to: "a", style: .normal, density: 4),
                .init(from: "conv", to: "d", style: .normal, density: 1),
            ])
            .frame(height: 260)
            VStack(alignment: .leading, spacing: 8) {
                Bullet(icon: "film", text: "Video ist unkomprimiert. Darum braucht ein HD-Strom 1–2,6 Gbit/s und einen 10-GbE-Anschluss.")
                Bullet(icon: "point.3.connected.trianglepath.dotted", text: "Weil die Essenzen getrennt sind, lassen sich Bild und Ton unabhängig verteilen – und müssen beim Empfänger wieder zusammenfinden.")
            }
        }
    }
}

private struct MulticastPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageText(title: "Multicast: einmal senden, gezielt empfangen",
                     lead: "Ein Sender schickt jeden Strom nur einmal ins Netz. Der Switch leitet ihn nur an Geräte weiter, die ihn mit IGMP angefordert haben.")
            FlowDiagram(nodes: [
                .init(id: "s", title: "Sender", subtitle: "239.21.1.1", icon: "dot.radiowaves.up.forward", x: 0.08, y: 0.5),
                .init(id: "sw", title: "Switch", subtitle: "IGMPv3-Snooping", icon: "rectangle.connected.to.line.below", x: 0.4, y: 0.5),
                .init(id: "r1", title: "Monitor", subtitle: "beigetreten", icon: "display", x: 0.84, y: 0.16),
                .init(id: "r2", title: "2110 Viewer", subtitle: "beigetreten", icon: "laptopcomputer", x: 0.84, y: 0.5),
                .init(id: "r3", title: "Recorder", subtitle: "nicht beigetreten", icon: "externaldrive", x: 0.84, y: 0.84),
            ], links: [
                .init(from: "s", to: "sw", style: .accent, density: 8),
                .init(from: "sw", to: "r1", style: .accent, density: 8),
                .init(from: "sw", to: "r2", style: .accent, density: 8),
                .init(from: "sw", to: "r3", style: .idle, density: 0),
            ])
            .frame(height: 260)
            VStack(alignment: .leading, spacing: 8) {
                Bullet(icon: "questionmark.circle", text: "Kommt nichts an, liegt es oft am Switch: Er braucht IGMP-Snooping und einen Querier, der die Anmeldungen regelmäßig abfragt.")
                Bullet(icon: "network", text: "2110 Viewer tritt der Gruppe auf genau der Netzwerkschnittstelle bei, die zum Sender passt, z. B. dem 10-GbE-Adapter.")
            }
        }
    }
}

private struct PTPPage: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageText(title: "Eine Uhr für alle: PTP",
                     lead: "Ein Grandmaster verteilt die Uhrzeit per PTP. Jedes Paket trägt einen Zeitstempel dieser Uhr. So weiß der Empfänger, welcher Ton zu welchem Bild gehört.")
            FlowDiagram(nodes: [
                .init(id: "gm", title: "Grandmaster", subtitle: "Domain 127", icon: "clock", x: 0.5, y: 0.12),
                .init(id: "c", title: "Converter", subtitle: "Follower", icon: "arrow.left.arrow.right.square", x: 0.14, y: 0.82),
                .init(id: "sw", title: "Switch", subtitle: "", icon: "rectangle.connected.to.line.below", x: 0.5, y: 0.82),
                .init(id: "m", title: "2110 Viewer", subtitle: "nur Follower", icon: "laptopcomputer", x: 0.86, y: 0.82),
            ], links: [
                .init(from: "gm", to: "c", style: .clock, density: 2),
                .init(from: "gm", to: "sw", style: .clock, density: 2),
                .init(from: "gm", to: "m", style: .clock, density: 2),
            ])
            .frame(height: 190)
            TimestampStrip()
                .frame(height: 96)
                .accessibilityLabel("Zeitachse: Videobilder alle 20 Millisekunden und Audiopakete jede Millisekunde tragen Zeitstempel derselben Uhr")
            Bullet(icon: "speaker.wave.2", text: "2110 Viewer richtet Bild und Ton an diesen Zeitstempeln aus. Ohne Grandmaster geht das auch, dann mit der Uhr des Macs. Die Diagnose misst den Versatz mit einem Blitz/Piep-Testsignal.")
        }
    }
}

private struct NMOSPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageText(title: "Finden und verbinden: NMOS",
                     lead: "Geräte kündigen ihre Ströme im Netz an (IS-04). 2110 Viewer findet sie ohne Konfiguration und kann Verbindungen herstellen (IS-05).")
            FlowDiagram(nodes: [
                .init(id: "c", title: "2110 IP Converter", subtitle: "„SDI 1 Video, Audio“", icon: "arrow.left.arrow.right.square", x: 0.14, y: 0.5),
                .init(id: "e", title: "2110 Viewer", subtitle: "zeigt die Quelle an", icon: "laptopcomputer", x: 0.86, y: 0.5),
            ], links: [
                .init(from: "c", to: "e", style: .accent, density: 3, label: "IS-04: Ich sende „SDI 1“"),
            ])
            .frame(height: 170)
            VStack(alignment: .leading, spacing: 8) {
                Bullet(icon: "magnifyingglass", text: "Der 3x3G meldet sich laut Blackmagic per mDNS, eine Registry ist nicht nötig. Findet 2110 Viewer nichts, hilft „Gerät per Adresse hinzufügen“.")
                Bullet(icon: "doc.text", text: "Die Beschreibung eines Stroms steht in einer SDP-Datei: Adresse, Format, Zeitbezug. 2110 Viewer liest sie automatisch oder per Drag-and-drop.")
                Bullet(icon: "dot.radiowaves.up.forward", text: "Beim Senden kündigt sich 2110 Viewer selbst so an. Der Converter kann den 2110-Viewer-Strom dann am SDI-Ausgang ausgeben.")
            }
        }
    }
}

private struct StartPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageText(title: "Drei Arbeitsweisen in 2110 Viewer",
                     lead: "Oben in der Symbolleiste wechseln Sie zwischen Empfangen, Senden und Analysieren.")
            HStack(alignment: .top, spacing: 16) {
                ModeCard(icon: "play.rectangle", title: "Empfangen", text: "Quelle links wählen, Bild sehen, Kanäle abhören. Die Diagnose zeigt Verluste und Synchronisation.")
                ModeCard(icon: "dot.radiowaves.up.forward", title: "Senden", text: "Testbild, Videodatei oder Kamera als ST 2110 ins Netz geben – z. B. an einen SDI-Ausgang des Converters.")
                ModeCard(icon: "waveform.path.ecg.rectangle", title: "Analysieren", text: "Paketmitschnitte prüfen: Zeitverhalten nach ST 2110-21, Audio-Laufzeit, PTP, IGMP.")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Was macOS fragen kann").font(.headline)
                Bullet(icon: "network", text: "Lokales Netzwerk: nötig für Geräteerkennung und Empfang. Bitte erlauben.")
                Bullet(icon: "shield.lefthalf.filled", text: "Eingehende Verbindungen (bei aktiver Firewall): für 2110 Viewer und das Hilfsprogramm gst-ptp-helper erlauben.")
                Bullet(icon: "camera", text: "Kamera und Mikrofon: nur, wenn Sie beim Senden eine Kamera wählen.")
            }
            Text("Ohne Netzwerk ausprobieren: „Demo: Testbild und Testton“ unten in der Seitenleiste.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

private struct ModeCard: View {
    let icon: String
    let title: String
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon).font(.title2).foregroundStyle(Color.accentColor).accessibilityHidden(true)
            Text(title).font(.headline)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(16)
        .cardBackground()
        .accessibilityElement(children: .combine)
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
                        Text(l.label!).font(.callout).foregroundStyle(.secondary)
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
        .accessibilityLabel(accessibilityText)
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
                Text(node.title).font(.callout.weight(.medium))
                if !node.subtitle.isEmpty { Text(node.subtitle).font(.caption).foregroundStyle(.secondary) }
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
            ctx.draw(Text("gleiche Zeit → gemeinsam wiedergeben").font(.caption).foregroundStyle(.secondary),
                     at: CGPoint(x: mx + 6, y: 2 * rowH + 20), anchor: .leading)
        }
    }
}
