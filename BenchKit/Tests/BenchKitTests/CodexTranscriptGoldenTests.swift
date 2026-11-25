import Foundation
import Testing
@testable import BenchKit

/// Recorded Codex sessions, read into the messages the chat shows. Like
/// Claude's, these are compared with saved copies, so a change to the
/// reader that changes a conversation fails a test.
struct CodexTranscriptGoldenTests {
    private static let mac = TranscriptParser.Options(keepsResults: true, keepsQueue: true, keepsNotices: true,
                                                      keepsTurnTimes: true, keepsCommands: true, keepsPatches: true)
    private static let plain = TranscriptParser.Options()

    private func messages(_ fixture: String, _ options: TranscriptParser.Options) throws -> [TranscriptMessage] {
        let format = CodexTranscriptFormat()
        return try Golden.lines("codex/rollout-\(fixture).jsonl").flatMap { format.messages(in: $0, options: options) }
    }

    @Test(arguments: ["tools", "simple"])
    func theMacChatReadsTheSameMessages(fixture: String) throws {
        try Golden.check(Golden.json(try messages(fixture, Self.mac)), "codex/\(fixture).mac.json")
    }

    @Test(arguments: ["tools", "simple"])
    func aPlainReaderReadsTheSameMessages(fixture: String) throws {
        try Golden.check(Golden.json(try messages(fixture, Self.plain)), "codex/\(fixture).plain.json")
    }

    @Test(arguments: ["tools", "simple"])
    func theMessagesGroupIntoTheSameTurns(fixture: String) throws {
        let turns = TranscriptTurn.group(try messages(fixture, Self.mac))
        let text = turns.map { turn -> String in
            func said(_ message: TranscriptMessage) -> String {
                String(message.text.replacingOccurrences(of: "\n", with: " ").prefix(60))
            }
            switch turn.kind {
            case .user(let message): return "user      \(said(message))"
            case .assistant(let message): return "assistant \(said(message))"
            case .image(let message): return "image     \(message.images.count)"
            case .system(let message): return "system    \(said(message))"
            case .steps(let steps):
                let rows = steps.map { step in
                    "  \(step.toolName ?? "-") | \(said(step))" + (turn.results[step.toolUseID ?? ""].map { " | result\($0.isError == true ? " (failed)" : "")" } ?? "")
                }
                return (["steps"] + rows).joined(separator: "\n")
            }
        }.joined(separator: "\n") + "\n"
        try Golden.check(text, "codex/\(fixture).turns.txt")
    }

    @Test func everyToolStepUsesTheSharedVocabulary() throws {
        for message in try messages("tools", Self.mac) where message.role == .tool && message.resultOf == nil {
            #expect(message.tool != nil, "\(message.toolName ?? "nil") has no kind")
        }
    }

    @Test func findsTheCommandInsideTheShellThatRanIt() {
        #expect(CodexTranscriptFormat.shellCommand(["/bin/zsh", "-lc", "ls -la"]) == "ls -la")
        #expect(CodexTranscriptFormat.shellCommand(["git", "status"]) == "git status")
        #expect(CodexTranscriptFormat.shellCommand("swift build") == "swift build")
        #expect(CodexTranscriptFormat.shellCommand(nil) == "")
    }

    @Test func readsAUnifiedDiffIntoAPatch() throws {
        let patch = try #require(EditPatch.from(unifiedDiff: "@@ -3,2 +3,3 @@\n keep\n-old\n+new\n+more\n", path: "/p/a.swift"))
        #expect(patch.hunks.count == 1)
        #expect(patch.hunks[0].oldStart == 3 && patch.hunks[0].newStart == 3)
        #expect(patch.additions == 2 && patch.deletions == 1)
        let edit = ToolEdit(patch: patch)
        #expect(edit.removed == ["old"] && edit.added == ["new", "more"])
        #expect(EditPatch.from(unifiedDiff: "", path: "/p/a.swift") == nil)
    }

    @Test func aLineThatIsntAnEventReadsAsNothing() {
        let format = CodexTranscriptFormat()
        #expect(format.messages(in: Data(#"{"type":"response_item","payload":{"type":"message"}}"#.utf8), options: Self.mac).isEmpty)
        #expect(format.messages(in: Data("not json event_msg".utf8), options: Self.mac).isEmpty)
    }
}
