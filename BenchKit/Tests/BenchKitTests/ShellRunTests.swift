import Foundation
import Testing
@testable import BenchKit

/// Commands you run yourself from the chat with a leading `!`, as Claude
/// Code's transcript records them.
@Suite struct ShellRunTests {
    private func userLine(_ content: String, id: String) -> Data {
        let entry: [String: Any] = ["type": "user", "uuid": id, "timestamp": "2026-11-07T13:00:00.000Z", "message": ["role": "user", "content": content]]
        return try! JSONSerialization.data(withJSONObject: entry)
    }

    @Test func aTypedMessageStartingWithABangIsACommand() {
        #expect(ShellRun.typed("! make test") == ShellRun(command: "make test"))
        #expect(ShellRun.typed("!make test") == ShellRun(command: "make test"))
        #expect(ShellRun.typed("  ! ls -la  ") == ShellRun(command: "ls -la"))
        #expect(ShellRun.typed("!") == nil)
        #expect(ShellRun.typed("! ") == nil)
        #expect(ShellRun.typed("Hello! Run the tests") == nil)
    }

    @Test func theCommandAndItsOutputAreReadFromTheTranscript() {
        let command = TranscriptParser.messages(in: userLine("<bash-input> echo bench-bang-42</bash-input>", id: "c"))
        #expect(command.count == 1)
        #expect(command.first?.role == .user)
        #expect(command.first?.text == "! echo bench-bang-42")
        #expect(command.first?.shell == ShellRun(command: "echo bench-bang-42"))

        let printed = TranscriptParser.messages(in: userLine("<bash-stdout>bench-bang-42</bash-stdout><bash-stderr></bash-stderr>", id: "o"))
        #expect(printed.first?.shell == ShellRun(command: "", stdout: "bench-bang-42", stderr: ""))
        #expect(printed.first?.text == "")
    }

    @Test func theOutputFoldsIntoTheCommandsTurn() {
        let messages = [
            TranscriptMessage(id: "a", role: .assistant, text: "Sure."),
            TranscriptMessage(id: "c", role: .user, text: "! make test", shell: ShellRun(command: "make test")),
            TranscriptMessage(id: "o", role: .user, text: "", shell: ShellRun(command: "", stdout: "ok\n", stderr: "")),
            TranscriptMessage(id: "r", role: .assistant, text: "Tests pass."),
        ]
        let turns = TranscriptTurn.group(messages)
        #expect(turns.map(\.id) == ["a", "c", "r"])
        guard case .user(let command) = turns[1].kind else { Issue.record("not a user turn"); return }
        #expect(command.shell == ShellRun(command: "make test", stdout: "ok\n", stderr: ""))
        #expect(command.shell?.isFinished == true)
        #expect(command.shell?.output == "ok")
    }

    @Test func outputWithNoCommandToJoinIsDropped() {
        let turns = TranscriptTurn.group([
            TranscriptMessage(id: "o", role: .user, text: "", shell: ShellRun(command: "", stdout: "x", stderr: "")),
            TranscriptMessage(id: "u", role: .user, text: "hi"),
        ])
        #expect(turns.map(\.id) == ["u"])
    }

    @Test func whatItPrintedReadsErrorsLastAndSpotsAFailure() {
        #expect(ShellRun(command: "x", stdout: "out\n", stderr: "warn\n").output == "out\n\nwarn")
        #expect(ShellRun(command: "x", stdout: "", stderr: "no such file").looksFailed)
        #expect(!ShellRun(command: "x", stdout: "fine", stderr: "a warning").looksFailed)
        #expect(!ShellRun(command: "x").looksFailed)
        #expect(ShellRun(command: "x").output == "")
    }

    @Test func otherTaggedNotesAreStillLeftOut() {
        #expect(TranscriptParser.messages(in: userLine("<system-reminder>be good</system-reminder>", id: "s")).isEmpty)
        #expect(TranscriptParser.messages(in: userLine("<local-command-stdout>x</local-command-stdout>", id: "l")).isEmpty)
    }

    @MainActor @Test func aSentBangMessageShowsAsACommandRightAway() {
        let outbox = Outbox()
        outbox.add(text: "! make test", queued: false, turns: [])
        let shown = outbox.merged([])
        guard case .user(let message) = shown.first?.kind else { Issue.record("no sent turn"); return }
        #expect(message.shell == ShellRun(command: "make test"))
        // Then the real entry takes over its bubble.
        let real = TranscriptTurn(id: "c", kind: .user(TranscriptMessage(id: "c", role: .user, text: "! make test", shell: ShellRun(command: "make test"))))
        #expect(outbox.merged([real]).map(\.id) == [message.id])
    }
}
