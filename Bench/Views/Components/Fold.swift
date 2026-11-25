import SwiftUI

/// Rows that fold away under a header. Opening, they're revealed from the
/// top as the space for them grows; closing, they're covered the same way
/// as it shrinks, and whatever is below follows along.
///
/// A plain `if` can't do the closing half: SwiftUI takes a removed view
/// out of its stack's layout at once, so the rows faded in place while
/// everything below slid up over them. Here the rows stay until they've
/// been covered, and are only then removed, so nothing folded away costs
/// anything while it's hidden.
struct Fold<Content: View>: View {
    let isOpen: Bool
    @ViewBuilder var content: Content
    @State private var mounted: Bool
    @State private var progress: CGFloat
    @Environment(\.motionLevel) private var motionLevel

    static var animation: Animation { .snappy(duration: 0.2) }

    init(isOpen: Bool, @ViewBuilder content: () -> Content) {
        self.isOpen = isOpen
        self.content = content()
        _mounted = State(initialValue: isOpen)
        _progress = State(initialValue: isOpen ? 1 : 0)
    }

    var body: some View {
        Group {
            if mounted {
                FoldReveal(progress: progress) { content }
                    .clipped()
                    .opacity(Double(progress))
                    // Not a transition of its own: the reveal is the animation.
                    .transition(.identity)
            }
        }
        .onChange(of: isOpen) { _, open in
            guard motionLevel != .still else {
                mounted = open
                progress = open ? 1 : 0
                return
            }
            if open {
                // In place first, at no height, then grown: a view that
                // arrives already at full size has nothing to animate from.
                mounted = true
                DispatchQueue.main.async {
                    withAnimation(Self.animation) { progress = 1 }
                }
            } else {
                withAnimation(Self.animation) {
                    progress = 0
                } completion: {
                    if !self.isOpen { mounted = false }
                }
            }
        }
    }
}

/// Takes up only part of its content's height, growing to all of it.
private struct FoldReveal: Layout {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let size = content.sizeThatFits(proposal)
        return CGSize(width: size.width, height: size.height * min(max(0, progress), 1))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}
