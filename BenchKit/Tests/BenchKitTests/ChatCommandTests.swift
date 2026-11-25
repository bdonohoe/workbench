import Testing
@testable import BenchKit

/// Which of Claude Code's commands the Mac's own chat handles itself.
@Suite struct ChatCommandTests {
    @Test func commandsThatPrintAreSentAsTyped() {
        #expect(ChatCommand(draft: "/context") == .prints)
        #expect(ChatCommand(draft: "/context all") == .prints)
        #expect(ChatCommand(draft: "/agents") == .prints)
        #expect(ChatCommand.prints.runsInChat == false)
    }

    @Test func resumeAloneOpensTheList() {
        #expect(ChatCommand(draft: "/resume") == .resume)
        #expect(ChatCommand(draft: "  /Resume \n") == .resume)
        // With a session named, Claude Code resumes it without a picker.
        #expect(ChatCommand(draft: "/resume 2caeace1") == nil)
        #expect(ChatCommand.resume.runsInChat)
    }

    @Test func usageGoesByThreeNames() {
        #expect(ChatCommand(draft: "/usage") == .usage)
        #expect(ChatCommand(draft: "/cost") == .usage)
        #expect(ChatCommand(draft: "/stats") == .usage)
    }

    @Test func statusAndHelpShowACard() {
        #expect(ChatCommand(draft: "/status") == .status)
        #expect(ChatCommand(draft: "/help") == .help)
    }

    @Test func exportAloneAsksWhereToSave() {
        #expect(ChatCommand(draft: "/export") == .export)
        // With a file named, Claude Code writes it without a dialog.
        #expect(ChatCommand(draft: "/export notes.txt") == nil)
    }

    @Test func otherMessagesAreLeftAlone() {
        #expect(ChatCommand(draft: "/compact") == nil)
        #expect(ChatCommand(draft: "resume") == nil)
        #expect(ChatCommand(draft: "/resume\nand then some") == nil)
        #expect(ChatCommand(draft: "/") == nil)
    }

    @Test func onlyClaudeCodesOwnCommandsAreHandled() {
        let own = SlashCommand(name: "resume", description: "", source: .builtIn, opensInTerminal: true)
        let yours = SlashCommand(name: "resume", description: "", source: .project)
        #expect(own.chatCommand == .resume)
        #expect(own.inLocalChat.opensInTerminal == false)
        #expect(yours.chatCommand == nil)
        // One the chat doesn't handle still needs the terminal.
        let hooks = SlashCommand(name: "hooks", description: "", source: .builtIn, opensInTerminal: true)
        #expect(hooks.inLocalChat.opensInTerminal)
    }
}
