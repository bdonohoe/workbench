import Foundation
import Testing
@testable import BenchKit

/// The message box's modes: `!` for a shell command, `/btw` for a side
/// question. A chip stands for the prefix and the field holds the rest.
@Suite struct ComposerDraftTests {
    @Test func modes() {
        #expect(ComposerDraft.mode(of: "! ls") == .shell)
        #expect(ComposerDraft.mode(of: "/btw why?") == .sideQuestion)
        #expect(ComposerDraft.mode(of: "/btw") == .sideQuestion)
        #expect(ComposerDraft.mode(of: "/BTW why?") == .sideQuestion)
        #expect(ComposerDraft.mode(of: "/btwx") == .message)
        #expect(ComposerDraft.mode(of: "/bt") == .message)
        #expect(ComposerDraft.mode(of: "say /btw later") == .message)
    }

    @Test func theFieldLeavesOutThePrefix() {
        #expect(ComposerDraft.fieldText(for: "/btw why that?") == "why that?")
        #expect(ComposerDraft.fieldText(for: "/btw ") == "")
        #expect(ComposerDraft.fieldText(for: "/btw") == "")
        #expect(ComposerDraft.fieldText(for: "! make test") == "make test")
        #expect(ComposerDraft.fieldText(for: "Hello") == "Hello")
        #expect(ComposerDraft.hiddenPrefixLength(in: "/btw why") == 5)
        #expect(ComposerDraft.hiddenPrefixLength(in: "! ls") == 2)
        #expect(ComposerDraft.hiddenPrefixLength(in: "Hello") == 0)
    }

    @Test func typingBtwSwitchesToASideQuestion() {
        #expect(ComposerDraft.draft(afterEditing: "/btw", in: .message) == "/btw ")
        #expect(ComposerDraft.draft(afterEditing: "/btw why that?", in: .message) == "/btw why that?")
        #expect(ComposerDraft.draft(afterEditing: "  /btw  why", in: .message) == "/btw why")
        #expect(ComposerDraft.draft(afterEditing: "/bt", in: .message) == "/bt")
        #expect(ComposerDraft.draft(afterEditing: "/btwx", in: .message) == "/btwx")
        #expect(ComposerDraft.draft(afterEditing: "!ls", in: .message) == "! ls")
    }

    @Test func typingInSideQuestionModeKeepsThePrefix() {
        #expect(ComposerDraft.draft(afterEditing: "why", in: .sideQuestion) == "/btw why")
        #expect(ComposerDraft.draft(afterEditing: " why", in: .sideQuestion) == "/btw why")
        #expect(ComposerDraft.draft(afterEditing: "", in: .sideQuestion) == "/btw ")
        for typed in ["why", "what does\nthis do?", "!"] {
            #expect(ComposerDraft.fieldText(for: ComposerDraft.draft(afterEditing: typed, in: .sideQuestion)) == typed)
        }
        // What's sent is what /btw has always sent.
        #expect(SideQuestion.question(in: ComposerDraft.draft(afterEditing: "why?", in: .sideQuestion)) == "why?")
    }

    @Test func leavingKeepsWhatWasTyped() {
        #expect(ComposerDraft.leaving("/btw why") == "why")
        #expect(ComposerDraft.leaving("/btw ") == "")
        #expect(ComposerDraft.leaving("! ls") == "ls")
    }

    @Test func aChipWithNothingAfterItIsEmpty() {
        #expect(ComposerDraft.isEmpty("/btw "))
        #expect(ComposerDraft.isEmpty("/btw"))
        #expect(ComposerDraft.isEmpty("! "))
        #expect(!ComposerDraft.isEmpty("/btw why"))
        #expect(!ComposerDraft.isEmpty(""))
        #expect(!ComposerDraft.isEmpty("Hello"))
    }
}
