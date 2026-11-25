import BenchKit
import SwiftUI

/// The chat view's type and link colors. The fonts follow the choices in
/// Settings and the text size from ⌘+ and ⌘−.
@MainActor
enum ChatStyle {
    private static var typography: ChatTypography { .shared }

    static var body: Font { typography.text(13.5) }
    static var small: Font { typography.text(12.5) }
    static var mono: Font { typography.code(12) }
    static var monoSmall: Font { typography.code(11.5) }
    /// What you type to Claude.
    static var input: Font { typography.text(14) }
    /// What you type after a `!`, to run in the shell.
    static var inputCommand: Font { typography.code(13) }
    static let link = StepColors.link

    static var steps: StepFonts { typography.steps }
    static var markdown: MarkdownFonts { typography.markdown }
    /// How the shared turn view draws on the Mac, in these fonts.
    static var turns: ChatTurnStyle { .mac(scale: typography.scale, body: body, small: small) }
}

enum ChatLayout {
    static let column: CGFloat = 720
}
