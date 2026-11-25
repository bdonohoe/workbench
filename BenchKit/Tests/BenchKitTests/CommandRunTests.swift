import Foundation
import Testing
@testable import BenchKit

/// Slash commands that print something, as Claude Code's transcript
/// records them. The shapes here are from a real session (v2.1.325).
@Suite struct CommandRunTests {
    private let options = TranscriptParser.Options(keepsCommands: true)

    private func userLine(_ content: String, id: String, meta: Bool = false) -> Data {
        let entry: [String: Any] = ["type": "user", "uuid": id, "isMeta": meta, "message": ["role": "user", "content": content]]
        return try! JSONSerialization.data(withJSONObject: entry)
    }

    private func noteLine(_ content: String, id: String) -> Data {
        let entry: [String: Any] = ["type": "system", "subtype": "local_command", "uuid": id, "content": content]
        return try! JSONSerialization.data(withJSONObject: entry)
    }

    private func echo(_ name: String, _ arguments: String = "") -> String {
        "<command-name>/\(name)</command-name>\n            <command-message>\(name)</command-message>\n            <command-args>\(arguments)</command-args>"
    }

    @Test func theCommandAndWhatItPrintedAreReadFromTheTranscript() {
        let command = TranscriptParser.messages(in: userLine(echo("export", "notes one.txt"), id: "c"), options: options)
        #expect(command.first?.command == CommandRun(name: "export", arguments: "notes one.txt"))
        #expect(command.first?.text == "/export notes one.txt")

        let printed = TranscriptParser.messages(in: noteLine("<local-command-stdout>Nothing to recap yet.</local-command-stdout>", id: "o"), options: options)
        #expect(printed.first?.command == CommandRun(name: "", output: "Nothing to recap yet."))
    }

    @Test func commandsRecordedAsClaudeCodesNotesAreReadToo() {
        let command = TranscriptParser.messages(in: noteLine(echo("context"), id: "c"), options: options)
        #expect(command.first?.command == CommandRun(name: "context"))
    }

    @Test func colorCodesAreTakenOut() {
        let printed = CommandRun.output(inTranscript: "<local-command-stdout> \u{1B}[1mContext Usage\u{1B}[22m\n\u{1B}[38;2;136;136;136m⛁ \u{1B}[39m</local-command-stdout>")
        #expect(printed == " Context Usage\n⛁ ")
    }

    @Test func nothingIsKeptUnlessAskedFor() {
        #expect(TranscriptParser.messages(in: userLine(echo("agents"), id: "c")).isEmpty)
        #expect(TranscriptParser.messages(in: noteLine("<local-command-stdout>Hi</local-command-stdout>", id: "o")).isEmpty)
        #expect(TranscriptParser.messages(in: userLine("## Context Usage\n\n**Tokens:** 1k", id: "m", meta: true)).isEmpty)
    }

    @Test func whatItPrintedJoinsTheCommandAsOneTurn() {
        let turns = TranscriptTurn.group([
            TranscriptMessage(id: "a", role: .assistant, text: "Done."),
            TranscriptMessage(id: "c", role: .user, text: "/agents", command: CommandRun(name: "agents")),
            TranscriptMessage(id: "o", role: .user, text: "", command: CommandRun(name: "", output: "The /agents wizard has been removed.")),
        ])
        #expect(turns.map(\.id) == ["a", "c"])
        guard case .user(let message) = turns[1].kind else { Issue.record("not a user turn"); return }
        #expect(message.command == CommandRun(name: "agents", output: "The /agents wizard has been removed."))
    }

    @Test func aCommandThatPrintsNothingWorthShowingIsNoTurn() {
        let turns = TranscriptTurn.group([
            TranscriptMessage(id: "c1", role: .user, text: "/model opus", command: CommandRun(name: "model", arguments: "opus")),
            TranscriptMessage(id: "o1", role: .user, text: "", command: CommandRun(name: "", output: "Set model to Opus 5.5")),
            TranscriptMessage(id: "c2", role: .user, text: "/simplify", command: CommandRun(name: "simplify")),
            TranscriptMessage(id: "o2", role: .user, text: "", command: CommandRun(name: "", output: "stray")),
            TranscriptMessage(id: "u", role: .user, text: "hi"),
        ])
        // The model switch is quiet; the second line of output has no command left to join.
        #expect(turns.map(\.id) == ["c2", "u"])
    }

    @Test func contextWaitsForItsMarkdown() {
        let turns = TranscriptTurn.group([
            TranscriptMessage(id: "c", role: .user, text: "/context", command: CommandRun(name: "context")),
            TranscriptMessage(id: "o", role: .user, text: "", command: CommandRun(name: "", output: "⛁ ⛁ ⛶")),
            TranscriptMessage(id: "m", role: .user, text: "", command: CommandRun(name: "", output: "## Context Usage", isMarkdown: true)),
        ])
        #expect(turns.count == 1)
        guard case .user(let message) = turns[0].kind else { Issue.record("not a user turn"); return }
        #expect(message.command == CommandRun(name: "context", output: "## Context Usage", isMarkdown: true))
    }

    @Test func theMarkdownCopyOfContextIsReadFromTheTranscript() {
        let copy = TranscriptParser.messages(in: userLine("## Context Usage\n\n**Tokens:** 41.3k / 500k (8%)", id: "m", meta: true), options: options)
        #expect(copy.first?.command?.isMarkdown == true)
        // A line ended with two spaces becomes a paragraph of its own.
        #expect(CommandRun.markdownOutput(inTranscript: "## Context Usage\n\n**Model:** haiku  \n**Tokens:** 1k") == "## Context Usage\n\n**Model:** haiku\n\n**Tokens:** 1k")
        // Other notes Claude Code makes for itself stay out.
        #expect(TranscriptParser.messages(in: userLine("<local-command-caveat>The command below…</local-command-caveat>", id: "x", meta: true), options: options).isEmpty)
    }
}
