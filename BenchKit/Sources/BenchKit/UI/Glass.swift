import SwiftUI

// Liquid Glass arrived in macOS 26. Workbench runs on macOS 15 too, so
// every view asks for glass through these, which use the real thing where
// it exists and a frosted material where it doesn't. Don't call
// `glassEffect`, `GlassEffectContainer`, `safeAreaBar` or
// `scrollEdgeEffectStyle` directly.

extension View {
    /// Glass in a shape, optionally tinted, optionally reacting to the
    /// pointer. Before macOS 26: the frosted material with a hairline and
    /// a soft shadow, so it still reads as floating over what's under it.
    public func benchGlass(in shape: some Shape, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(BenchGlass(shape: shape, tint: tint, interactive: interactive))
    }

    /// A bar along the top or bottom that the content scrolls under.
    /// Before macOS 26 it's a plain safe area inset: the content still
    /// runs under it, without the edge treatment.
    @ViewBuilder
    public func benchSafeAreaBar(edge: VerticalEdge, spacing: CGFloat? = nil,
                                 @ViewBuilder content: () -> some View) -> some View {
        if #available(macOS 26, iOS 26, *) {
            safeAreaBar(edge: edge, spacing: spacing, content: content)
        } else {
            safeAreaInset(edge: edge, spacing: spacing, content: content)
        }
    }

    /// Fades scrolled content softly at these edges. Nothing before
    /// macOS 26, where there's no edge effect to soften.
    @ViewBuilder
    public func benchSoftScrollEdge(_ edges: Edge.Set) -> some View {
        if #available(macOS 26, iOS 26, *) {
            scrollEdgeEffectStyle(.soft, for: edges)
        } else {
            self
        }
    }
}

/// Groups glass shapes so they blend where they meet. Before macOS 26 the
/// content is shown as it is.
public struct BenchGlassContainer<Content: View>: View {
    private let spacing: CGFloat?
    private let content: Content

    public init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        if #available(macOS 26, iOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

private struct BenchGlass<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color?
    let interactive: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26, iOS 26, *) {
            content.glassEffect(glass, in: shape)
        } else {
            content.background {
                shape
                    .fill(.regularMaterial)
                    .overlay(shape.fill(tint ?? .clear))
                    .overlay(shape.stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            }
        }
    }

    @available(macOS 26, iOS 26, *)
    private var glass: Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }
}
