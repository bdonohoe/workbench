import SwiftUI
import Testing
@testable import BenchKit

struct ChatTurnStyleTests {
    /// Each platform keeps the room it had for your messages.
    @Test func eachPlatformKeepsItsInset() {
        #expect(ChatTurnStyle.phone.userInset == 48)
        #expect(ChatTurnStyle.mac(scale: 1).userInset == 120)
    }

    /// ⌘+ on the Mac grows the words and the mark beside them together.
    @Test func macTypeFollowsTheScale() {
        let usual = ChatTurnStyle.mac(scale: 1)
        let bigger = ChatTurnStyle.mac(scale: 1.4)
        #expect(bigger.bodyFont != usual.bodyFont)
        #expect(bigger.smallFont != usual.smallFont)
        #expect(bigger.mark.size == 14 * 1.4)
        #expect(usual.mark.size == 14)
    }

    /// The Mac's own fonts, when it passes them, are used as given.
    @Test func macKeepsTheFontsItIsGiven() {
        let chosen = Font.custom("Georgia", fixedSize: 20)
        let style = ChatTurnStyle.mac(scale: 1, body: chosen)
        #expect(style.bodyFont == chosen)
        #expect(style.bodyFont != ChatTurnStyle.mac(scale: 1).bodyFont)
    }

    /// Only the Mac has a pointer to hover with.
    @Test func onlyTheMacCopiesOnHover() {
        #expect(!ChatTurnStyle.phone.copyOnHover)
        #expect(ChatTurnStyle.mac(scale: 1).copyOnHover)
    }
}
