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

    /// Schaltflächenstil: Glas ab macOS 26, sonst „bordered“.
    @ViewBuilder
    func controlButtonStyle(prominent: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
        #else
        if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        #endif
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
