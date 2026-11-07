import AppKit
import SwiftUI

// Liquid Glass ab macOS 26 (offizielle SwiftUI-APIs), sonst native Materialien.
// Glas wird nur auf Bedienelemente angewendet, nie auf das Videobild.

extension View {
    /// Fläche für Bedienelemente.
    @ViewBuilder
    func controlSurface(cornerRadius: CGFloat = 18) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.modifier(FallbackSurface(cornerRadius: cornerRadius))
        }
        #else
        self.modifier(FallbackSurface(cornerRadius: cornerRadius))
        #endif
    }

    /// Schaltflächenstil wie in Apples Apps: Kapsel, Glas ab macOS 26, sonst „bordered“.
    @ViewBuilder
    func controlButtonStyle(prominent: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent).buttonBorderShape(.capsule) } else { self.buttonStyle(.glass).buttonBorderShape(.capsule) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent).buttonBorderShape(.capsule) } else { self.buttonStyle(.bordered).buttonBorderShape(.capsule) }
        }
        #else
        if prominent { self.buttonStyle(.borderedProminent).buttonBorderShape(.capsule) } else { self.buttonStyle(.bordered).buttonBorderShape(.capsule) }
        #endif
    }

    /// Runde Symbolschaltfläche (Stumm, Vollbild …), neutral, nicht eingefärbt.
    @ViewBuilder
    func iconButtonStyle() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass).buttonBorderShape(.circle)
        } else {
            self.buttonStyle(.bordered).buttonBorderShape(.circle)
        }
        #else
        self.buttonStyle(.bordered).buttonBorderShape(.circle)
        #endif
    }

    /// Menü als Kapsel-Schaltfläche in Bedienleisten.
    func controlMenuStyle(indicator: Bool = true) -> some View {
        self.menuStyle(.button)
            .menuIndicator(indicator ? .visible : .hidden)
            .controlButtonStyle()
    }

    /// Hintergrund für gruppierte Inhalte (wie die Gruppen in den Systemeinstellungen).
    func cardBackground(cornerRadius: CGFloat = Theme.cardRadius) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(Color(nsColor: .quaternarySystemFill), in: shape)
            .overlay(shape.strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5))
    }
}

/// Gruppe mit Überschrift über der Fläche – entspricht `Section` in einem
/// gruppierten Formular, funktioniert aber auch in Spalten und Inspektoren.
struct GroupedBox<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr(title))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 10) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .cardBackground()
        }
    }
}

/// Gruppiert Glas-Elemente (macOS 26), sonst einfacher Container.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

private struct FallbackSurface: ViewModifier {
    var cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency {
            content.background(Color(nsColor: .windowBackgroundColor), in: shape)
                .overlay(shape.strokeBorder(Color.secondary.opacity(0.3)))
        } else {
            content.background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.08)))
        }
    }
}


/// Farbwelt: Systemflächen und die Akzentfarbe des Systems.
enum Theme {
    /// Systemakzentfarbe (folgt Systemeinstellungen › Erscheinungsbild), wie in Apples Apps.
    static let accent = Color.accentColor
    static let cardRadius: CGFloat = 12
}
