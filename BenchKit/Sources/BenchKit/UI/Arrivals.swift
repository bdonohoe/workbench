import SwiftUI

/// How a new message comes into the chat: up from just below, fading in,
/// while everything above it glides up to make room.
public enum ChatMotion {
    /// The glide. A little settle at the end, nothing bouncy.
    public static let arrive = Animation.spring(duration: 0.42, bounce: 0.12)

    /// A new row rises into place and fades in. Leaving, it just fades.
    public static var row: AnyTransition { .asymmetric(
        insertion: .modifier(active: Rising(progress: 0), identity: Rising(progress: 1)),
        removal: .opacity) }

    /// A message you just sent: it lifts out of the message box under it
    /// and settles into the conversation, so it's plain where your words
    /// went. Leaving, it just fades.
    public static var sent: AnyTransition { .asymmetric(
        insertion: .modifier(active: Rising(progress: 0, lift: 44, from: 0.98, clips: false),
                             identity: Rising(progress: 1, lift: 44, from: 0.98, clips: false)),
        removal: .opacity) }

    /// Cards and bars above the message box coming and going, and their
    /// lists folding open.
    public static let dock = Animation.snappy(duration: 0.25)

    /// A card arriving above the message box: up a few points as it fades
    /// in, and a plain fade out. Not a slide from below: that starts it
    /// inside the message box, where it shows through the glass.
    public static var card: AnyTransition { .asymmetric(
        insertion: .modifier(active: Settling(progress: 0), identity: Settling(progress: 1)),
        removal: .opacity) }

    /// The same for a glass bar, which can't fade (the conversation shows
    /// through glass until a fade lands): it grows a little from its
    /// bottom edge. Put the bar in its own `GlassEffectContainer` so the
    /// glass and what's on it grow as one piece.
    public static var glassCard: AnyTransition {
        .modifier(active: Growing(progress: 0, from: 0.97, anchor: .bottom),
                  identity: Growing(progress: 1, from: 0.97, anchor: .bottom))
    }

    /// A glass list opening from the control it belongs to: it grows a
    /// little out of that corner. Never a fade, for the same reason.
    public static func glassList(from corner: UnitPoint) -> AnyTransition {
        .modifier(active: Growing(progress: 0, from: 0.94, anchor: corner),
                  identity: Growing(progress: 1, from: 0.94, anchor: corner))
    }

    /// The arrival for this turn. A long one just fades in: growing its
    /// height measures all of its text again on every frame, which for a
    /// big paste can stall the whole window.
    public static func row(for turn: TranscriptTurn) -> AnyTransition {
        if turn.isLong { return .opacity }
        if case .user = turn.kind { return sent }
        return row
    }
}

public extension TranscriptTurn {
    /// Lots of text: too much to animate the height of.
    var isLong: Bool {
        switch kind {
        case .user(let message), .assistant(let message), .system(let message):
            message.text.utf8.count > 2_000
        case .image, .steps:
            false
        }
    }
}

/// Fades in while rising the last few points. Just a fade with motion
/// turned down.
private struct Settling: ViewModifier {
    let progress: CGFloat
    @Environment(\.motionLevel) private var motionLevel

    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .offset(y: motionLevel == .still ? 0 : 8 * (1 - progress))
    }
}

/// Grows from a little under full size, out of one corner or edge. With
/// motion turned down it's simply there.
private struct Growing: ViewModifier {
    let progress: CGFloat
    let from: CGFloat
    let anchor: UnitPoint
    @Environment(\.motionLevel) private var motionLevel

    func body(content: Content) -> some View {
        content.scaleEffect(motionLevel == .still ? 1 : from + (1 - from) * progress, anchor: anchor)
    }
}

private struct Rising: ViewModifier {
    let progress: CGFloat
    /// How far below its place it starts.
    var lift: CGFloat = 18
    /// The size it starts at.
    var from: CGFloat = 0.96
    /// Whether it's hidden outside the room it has made so far. A sent
    /// message isn't: it starts over the message box and rises from it.
    var clips = true
    @Environment(\.motionLevel) private var motionLevel

    func body(content: Content) -> some View {
        // With motion turned down the row only fades: nothing lifts or
        // grows, and the chat above steps up rather than gliding.
        let still = motionLevel == .still
        // The row's height grows in, so the chat above glides up as it
        // makes room, while the row itself fades and lifts into place.
        Reveal(progress: still ? 1 : progress) {
            content
                .opacity(progress)
                .scaleEffect(still ? 1 : from + (1 - from) * progress, anchor: .bottomTrailing)
                .offset(y: still ? 0 : lift * (1 - progress))
        }
        // Only the part it has made room for shows. The row is drawn at
        // full height from the start, so unclipped it sat on top of
        // whatever is under it (the Working line) until it finished
        // arriving. Once it has arrived, nothing is clipped.
        .clipShape(Rectangle().inset(by: clips && progress < 1 ? 0 : -10_000))
    }
}

/// Takes up only part of its content's height, growing to all of it.
private struct Reveal: Layout {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let size = content.sizeThatFits(proposal)
        return CGSize(width: size.width, height: size.height * max(0, progress))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

public extension View {
    /// Takes up `progress` of its height, from none of it at 0 to all of
    /// it at 1, showing only the part it has room for and fading with it.
    /// Animate `progress` and the view opens out a frame at a time, so
    /// everything around it moves with it. Putting a view in and out of
    /// a stack with `if` changes the stack's size all at once instead,
    /// and whatever sits outside the animation jumps.
    func revealed(_ progress: CGFloat) -> some View {
        Reveal(progress: progress) { self }
            // Only the height is cut off: a rule that runs past the sides stays whole.
            .clipShape(Rectangle().scale(x: 3, y: 1))
            .opacity(progress)
            .accessibilityHidden(progress == 0)
    }

    /// Animates rows coming in at the end of a chat. Only a few new ones at
    /// the end count, so opening or switching conversations doesn't animate.
    func animatesArrivals(_ ids: [String]) -> some View {
        modifier(Arrivals(ids: ids))
    }
}

private struct Arrivals: ViewModifier {
    let ids: [String]
    @State private var previous: [String]?

    private var isArrival: Bool {
        guard let previous, !previous.isEmpty, ids.count > previous.count, ids.count - previous.count <= 4 else { return false }
        // Everything that was there is still there, in order, with the new
        // rows after it (a queued bubble at the very end can move along).
        let kept = ids.filter(Set(previous).contains)
        return kept == previous.filter(Set(ids).contains) && kept.count >= previous.count - 1
    }

    func body(content: Content) -> some View {
        content
            .animation(isArrival ? ChatMotion.arrive : nil, value: ids)
            .onAppear { previous = ids }
            .onChange(of: ids) { _, new in previous = new }
    }
}
