import SwiftUI

/// How one turn of the conversation is drawn. The Mac and the iPhone share
/// `TranscriptTurnView`; everything that differs between them is a value
/// here, so each platform's chat looks the way it did when it had a view
/// of its own. The phone's values are the default. The Mac puts `.mac` in
/// the environment where it builds the transcript.
public struct ChatTurnStyle: Sendable {
    /// The bubble around what you typed.
    public enum UserBubble: Sendable {
        /// A soft tint of the accent, with the bottom trailing corner
        /// tucked in like a speech bubble. Queued, it fades and takes a
        /// dashed outline in the muted ink.
        case tail(radius: CGFloat, tailRadius: CGFloat)
        /// A pill in the accent color, as in Messages. Queued, it's a
        /// dashed outline in the accent, not yet a sent bubble.
        case accent(radius: CGFloat)
    }

    /// Claude's ✻ beside its words.
    public struct Mark: Sendable {
        public var size: CGFloat
        /// The column the mark sits in, so the words start at the same
        /// place whatever the glyph's width.
        public var width: CGFloat
        /// Between the mark and the words.
        public var spacing: CGFloat
        /// Pushes the mark down to the middle of the first line.
        public var topPadding: CGFloat

        public init(size: CGFloat, width: CGFloat, spacing: CGFloat, topPadding: CGFloat) {
            self.size = size
            self.width = width
            self.spacing = spacing
            self.topPadding = topPadding
        }
    }

    /// Notes from Claude Code, like compacting: easy to miss as a thin
    /// line, so they get a card of their own.
    public struct SystemRow: Sendable {
        public enum Fill: Sendable {
            case surface
            case raised
        }
        public var fill: Fill
        public var radius: CGFloat
        public var stroked: Bool
        /// True to center the note with its detail under it, as the phone
        /// does. Otherwise the icon sits beside a left-aligned note and
        /// detail, which reads better in the Mac's wide column.
        public var centered: Bool
        public var titleFont: Font
        public var detailFont: Font

        public init(fill: Fill, radius: CGFloat, stroked: Bool, centered: Bool, titleFont: Font, detailFont: Font) {
            self.fill = fill
            self.radius = radius
            self.stroked = stroked
            self.centered = centered
            self.titleFont = titleFont
            self.detailFont = detailFont
        }
    }

    /// Your words and Claude's.
    public var bodyFont: Font
    /// Captions, like the note under a queued message.
    public var smallFont: Font
    public var lineSpacing: CGFloat
    /// How far Claude's steps and pictures sit in from its mark, to line
    /// up with its words.
    public var indent: CGFloat
    /// The same for a task notice. The phone leaves notices at the edge.
    public var noticeIndent: CGFloat
    public var userBubble: UserBubble
    /// Above and below your words inside the bubble.
    public var userBubblePadding: CGFloat
    /// Room kept clear on the leading side of your messages, so they read
    /// as yours even when they're long.
    public var userInset: CGFloat
    public var mark: Mark
    public var systemRow: SystemRow
    /// True to show a copy button beside a message while the pointer is
    /// over it. Only the Mac has a pointer; the phone copies by selecting.
    public var copyOnHover: Bool

    public init(bodyFont: Font, smallFont: Font, lineSpacing: CGFloat, indent: CGFloat, noticeIndent: CGFloat,
                userBubble: UserBubble, userBubblePadding: CGFloat, userInset: CGFloat, mark: Mark,
                systemRow: SystemRow, copyOnHover: Bool) {
        self.bodyFont = bodyFont
        self.smallFont = smallFont
        self.lineSpacing = lineSpacing
        self.indent = indent
        self.noticeIndent = noticeIndent
        self.userBubble = userBubble
        self.userBubblePadding = userBubblePadding
        self.userInset = userInset
        self.mark = mark
        self.systemRow = systemRow
        self.copyOnHover = copyOnHover
    }

    /// The iPhone's chat, in the system fonts so it follows Dynamic Type.
    public static let phone = ChatTurnStyle(
        bodyFont: .body,
        smallFont: .caption,
        lineSpacing: 0,
        indent: 26,
        noticeIndent: 0,
        userBubble: .accent(radius: 20),
        userBubblePadding: 10,
        userInset: 48,
        mark: Mark(size: 13, width: 16, spacing: 10, topPadding: 4),
        systemRow: SystemRow(fill: .raised, radius: 14, stroked: true, centered: true,
                             titleFont: .system(.footnote, design: .rounded, weight: .semibold),
                             detailFont: .caption),
        copyOnHover: false)

    /// The Mac's chat at the text size from ⌘+ and ⌘−, where 1 is the usual
    /// size. The fonts default to the system's at the Mac's sizes; the Mac
    /// passes its own, in the family chosen in Settings.
    public static func mac(scale: CGFloat, body: Font? = nil, small: Font? = nil) -> ChatTurnStyle {
        let small = small ?? .system(size: 12.5 * scale)
        return ChatTurnStyle(
            bodyFont: body ?? .system(size: 13.5 * scale),
            smallFont: small,
            lineSpacing: 2,
            indent: 28,
            noticeIndent: 28,
            userBubble: .tail(radius: 16, tailRadius: 5),
            userBubblePadding: 9,
            userInset: 120,
            // Drawn at its size rather than scaled up, so the mark stays sharp.
            mark: Mark(size: 14 * scale, width: 14 * scale + 2, spacing: 12, topPadding: 3),
            systemRow: SystemRow(fill: .surface, radius: 10, stroked: false, centered: false,
                                 titleFont: small.weight(.semibold), detailFont: small),
            copyOnHover: true)
    }
}

extension EnvironmentValues {
    /// How the chat's turns are drawn. The phone's style unless a platform
    /// sets its own.
    @Entry public var chatTurnStyle = ChatTurnStyle.phone
    /// How the cards above the message box are drawn. The phone's style
    /// unless a platform sets its own.
    @Entry public var dockCardStyle = DockCardStyle.phone
}

/// How the cards above the message box are drawn: a question, a side
/// question, the compacting note. The phone's values are the default and
/// leave each card the shape it has there. The Mac sets one radius, one
/// border and one title for all of them, in its chat's own fonts.
public struct DockCardStyle: Sendable {
    /// The cards' corner radius, or nil to leave each card its own.
    public var radius: CGFloat?
    /// The width of the colored outline, or nil to leave each card its own.
    public var borderWidth: CGFloat?
    /// The line that names the card, like "Claude has a question".
    public var title: Font
    /// The question itself.
    public var heading: Font
    /// Choices and answers.
    public var body: Font
    /// Notes under a choice, and other small print.
    public var caption: Font
    /// The label on the card's main button.
    public var action: Font
    /// True for a small main button at the trailing edge, beside a
    /// pointer. Otherwise it fills the card's width, for a thumb.
    public var compactActions: Bool

    public init(radius: CGFloat?, borderWidth: CGFloat?, title: Font, heading: Font, body: Font, caption: Font,
                action: Font, compactActions: Bool) {
        self.radius = radius
        self.borderWidth = borderWidth
        self.title = title
        self.heading = heading
        self.body = body
        self.caption = caption
        self.action = action
        self.compactActions = compactActions
    }

    /// The iPhone's cards, in the system fonts so they follow Dynamic Type.
    public static let phone = DockCardStyle(
        radius: nil, borderWidth: nil,
        title: .system(.subheadline, design: .rounded, weight: .semibold),
        heading: .body, body: .callout, caption: .caption, action: .body,
        compactActions: false)
}
