import Foundation
import Testing
@testable import BenchKit

@Suite struct PlanTextTests {
    private func line(_ tool: String, _ input: [String: Any], id: String = "u1") -> Data {
        let entry: [String: Any] = [
            "type": "assistant", "uuid": id,
            "message": ["content": [["type": "tool_use", "id": "t-\(id)", "name": tool, "input": input]]],
        ]
        return try! JSONSerialization.data(withJSONObject: entry)
    }

    @Test func planFilesAreRecognized() {
        #expect(PlanText.isPlanFile("/Users/a/.claude/plans/fancy-bear.md"))
        #expect(PlanText.isPlanFile("/Users/a/.config/claude/plans/scalable-hopper.md"))
        #expect(!PlanText.isPlanFile("/Users/a/project/plans/notes.txt"))
        #expect(!PlanText.isPlanFile("/Users/a/project/README.md"))
        #expect(!PlanText.isPlanFile(nil))
    }

    @Test func writingAPlanFileKeepsTheWholePlan() {
        let content = (1...104).map { "Line \($0)" }.joined(separator: "\n")
        let message = TranscriptParser.messages(in: line("Write", ["file_path": "/h/.claude/plans/p.md", "content": content]))[0]
        #expect(message.plan == content)
        // The diff stays trimmed as before.
        #expect(message.edit?.added.count == ToolEdit.shownLines)
    }

    @Test func otherWritesCarryNoPlan() {
        let message = TranscriptParser.messages(in: line("Write", ["file_path": "/p/README.md", "content": "Hi"]))[0]
        #expect(message.plan == nil)
    }

    @Test func approvalCarriesItsOwnPlan() {
        let message = TranscriptParser.messages(in: line("ExitPlanMode", ["plan": "# Plan\n\nDo it."]))[0]
        #expect(message.plan == "# Plan\n\nDo it.")
    }

    @Test func approvalWithoutAPlanReadsTheLastPlanFile() {
        var messages = TranscriptParser.messages(in: line("Write", ["file_path": "/h/.claude/plans/p.md", "content": "Old"], id: "a"))
            + TranscriptParser.messages(in: line("ExitPlanMode", [:], id: "b"))
        var last: String?
        PlanText.fill(&messages, lastFile: &last) { $0 == "/h/.claude/plans/p.md" ? "Edited since" : nil }
        #expect(messages[1].plan == "Edited since")
        #expect(last == "/h/.claude/plans/p.md")

        // The file carries over to the next batch.
        var next = TranscriptParser.messages(in: line("ExitPlanMode", [:], id: "c"))
        PlanText.fill(&next, lastFile: &last) { _ in "Again" }
        #expect(next[0].plan == "Again")
    }

    @Test func oldMessagesWithoutAPlanStillDecode() throws {
        let json = #"{"id":"x","role":"tool","text":"Asked","toolName":"ExitPlanMode"}"#
        let message = try JSONDecoder().decode(TranscriptMessage.self, from: Data(json.utf8))
        #expect(message.plan == nil)
    }
}
