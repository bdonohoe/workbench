import Foundation
import Testing
@testable import BenchKit

/// The message box's shell mode: the `!` shows as a chip, and the field
/// holds only the command.
@Suite struct ShellDraftTests {
    @Test func aDraftStartingWithABangIsInShellMode() {
        #expect(ShellDraft.isShell("! make test"))
        #expect(ShellDraft.isShell("!"))
        #expect(!ShellDraft.isShell("Hello! Run the tests"))
        #expect(!ShellDraft.isShell(""))
    }

    @Test func theFieldShowsTheCommandWithoutItsBang() {
        #expect(ShellDraft.fieldText(for: "! make test") == "make test")
        #expect(ShellDraft.fieldText(for: "!make test") == "make test")
        #expect(ShellDraft.fieldText(for: "!") == "")
        #expect(ShellDraft.fieldText(for: "! ") == "")
        #expect(ShellDraft.fieldText(for: "Run the tests") == "Run the tests")
    }

    @Test func aPlaceInTheFieldMapsToTheDraft() {
        #expect(ShellDraft.hiddenPrefixLength(in: "! make test") == 2)
        #expect(ShellDraft.hiddenPrefixLength(in: "!make test") == 1)
        #expect(ShellDraft.hiddenPrefixLength(in: "Run the tests") == 0)
    }

    @Test func typingInShellModeKeepsTheBangInTheDraft() {
        #expect(ShellDraft.draft(afterEditing: "cd Apps", inShellMode: true) == "! cd Apps")
        #expect(ShellDraft.draft(afterEditing: "", inShellMode: true) == "! ")
        // What the field shows matches what was typed into it.
        for typed in ["cd Apps", "", "ls -la ", "echo !"] {
            #expect(ShellDraft.fieldText(for: ShellDraft.draft(afterEditing: typed, inShellMode: true)) == typed)
        }
        // A space typed before the command out of habit is dropped.
        #expect(ShellDraft.draft(afterEditing: " ", inShellMode: true) == "! ")
        #expect(ShellDraft.draft(afterEditing: " ls", inShellMode: true) == "! ls")
    }

    @Test func aMessageThatTurnsIntoACommandEntersShellMode() {
        #expect(ShellDraft.draft(afterEditing: "!", inShellMode: false) == "! ")
        #expect(ShellDraft.draft(afterEditing: "!cd Apps", inShellMode: false) == "! cd Apps")
        #expect(ShellDraft.draft(afterEditing: "  ! cd Apps", inShellMode: false) == "! cd Apps")
        #expect(ShellDraft.draft(afterEditing: "Hello!", inShellMode: false) == "Hello!")
    }

    @Test func leavingShellModeKeepsWhatYouTyped() {
        #expect(ShellDraft.leaving("! cd Apps") == "cd Apps")
        #expect(ShellDraft.leaving("! ") == "")
    }

    @Test func aBangWithNoCommandHasNothingToSend() {
        #expect(ShellDraft.isEmptyCommand("!"))
        #expect(ShellDraft.isEmptyCommand("!  "))
        #expect(!ShellDraft.isEmptyCommand("! ls"))
        #expect(!ShellDraft.isEmptyCommand(""))
        // What the draft sends still reads as the same command.
        #expect(ShellRun.typed(ShellDraft.draft(forCommand: "make test")) == ShellRun(command: "make test"))
    }
}
