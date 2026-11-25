import Foundation
import Testing
@testable import BenchKit

/// Recorded Claude Code sessions, read the way the Mac chat and the phone
/// read them. These pin today's results so that moving the reader behind a
/// provider can't quietly change what a conversation looks like.
struct ClaudeTranscriptGoldenTests {
    /// What the Mac's own chat asks the reader to keep (`LocalChatSource`).
    private static let mac = TranscriptParser.Options(keepsResults: true, keepsQueue: true, keepsNotices: true,
                                                      keepsTurnTimes: true, keepsCommands: true, keepsPatches: true)
    /// The least a reader keeps: what an older phone is sent.
    private static let plain = TranscriptParser.Options()

    private func messages(_ fixture: String, _ options: TranscriptParser.Options) throws -> [TranscriptMessage] {
        try Golden.lines("claude/\(fixture).jsonl").flatMap { TranscriptParser.messages(in: $0, options: options) }
    }

    @Test(arguments: ["tools", "interactive"])
    func theMacChatReadsTheSameMessages(fixture: String) throws {
        try Golden.check(Golden.json(try messages(fixture, Self.mac)), "claude/\(fixture).mac.json")
    }

    @Test(arguments: ["tools", "interactive"])
    func aPlainReaderReadsTheSameMessages(fixture: String) throws {
        try Golden.check(Golden.json(try messages(fixture, Self.plain)), "claude/\(fixture).plain.json")
    }

    @Test(arguments: ["tools", "interactive"])
    func theSubagentsTranscriptReadsTheSame(fixture: String) throws {
        guard fixture == "tools" else { return }
        let lines = try Golden.lines("claude/tools/subagents/agent-a5d9acd75575bd71d.jsonl")
        // A subagent's lines are marked as a side conversation, which the
        // reader of the main one leaves out.
        #expect(lines.flatMap { TranscriptParser.messages(in: $0, options: Self.mac) }.isEmpty)
    }

    /// The messages folded into the rows the chat draws.
    @Test(arguments: ["tools", "interactive"])
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
        try Golden.check(text, "claude/\(fixture).turns.txt")
    }
}
