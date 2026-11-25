import BenchKit
import Foundation
import Testing
@testable import Bench

/// Working out a session's effort level from what Claude Code wrote.
struct EffortTests {
    @Test func readsClaudeCodesNote() {
        let entry: [String: Any] = ["type": "user", "message": ["content":
            "<local-command-stdout>Set effort level to medium (saved as your default for new sessions): Balanced approach</local-command-stdout>"]]
        #expect(ClaudeSessionStats.setEffort(entry) == "medium")
        #expect(ClaudeSessionStats.setEffort(["type": "user", "message": ["content": "hello"]]) == nil)
    }

    @Test func modelIDFromName() {
        #expect(ClaudeEffort.modelID("Opus 5.5") == "claude-opus-5-5")
        #expect(ClaudeEffort.modelID("Fable 5.1") == "claude-fable-5-1")
    }

    @Test func newerOfSentAndTranscriptWins() {
        let now = Date()
        var info = TranscriptInfo()
        info.effort = "low"
        info.effortAt = now
        #expect(TerminalManager.effort(sent: ("max", now.addingTimeInterval(5)), transcript: info, saved: nil) == "max")
        #expect(TerminalManager.effort(sent: ("max", now.addingTimeInterval(-5)), transcript: info, saved: nil) == "low")
    }
}
