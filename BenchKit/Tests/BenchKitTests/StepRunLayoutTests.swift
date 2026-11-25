import Foundation
import Testing
@testable import BenchKit

struct StepRunLayoutTests {
    private func read(_ id: String) -> TranscriptMessage {
        TranscriptMessage(id: id, role: .tool, text: "Reading a.swift", detail: "/p/a.swift", toolName: "Read", toolUseID: id)
    }

    private func edit(_ id: String, _ path: String) -> TranscriptMessage {
        TranscriptMessage(id: id, role: .tool, text: "Editing", detail: path, toolName: "Edit",
                          edit: ToolEdit(removed: ["a"], added: ["b"], removedCount: 1, addedCount: 1, isNewFile: false), toolUseID: id)
    }

    private func command(_ id: String) -> TranscriptMessage {
        TranscriptMessage(id: id, role: .tool, text: "Ran the tests", detail: "swift test", toolName: "Bash", toolUseID: id)
    }

    @Test func readsEditsAndCommandsShareOneThread() {
        let pieces = StepRunLayout.pieces(for: [read("1"), read("2"), edit("3", "/p/a.swift"), command("4"), read("5")])
        #expect(pieces == [.thread([
            .quiet([read("1"), read("2")]),
            .edit([edit("3", "/p/a.swift")]),
            .command(command("4")),
            .quiet([read("5")]),
        ])])
    }

    @Test func editsToOneFileInARowShareALine() {
        let pieces = StepRunLayout.pieces(for: [edit("1", "/p/a.swift"), edit("2", "/p/a.swift"), edit("3", "/p/b.swift"), edit("4", "/p/a.swift")])
        #expect(pieces == [.thread([
            .edit([edit("1", "/p/a.swift"), edit("2", "/p/a.swift")]),
            .edit([edit("3", "/p/b.swift")]),
            .edit([edit("4", "/p/a.swift")]),
        ])])
    }

    @Test func aStepBetweenTwoEditsKeepsThemApart() {
        let pieces = StepRunLayout.pieces(for: [edit("1", "/p/a.swift"), read("2"), edit("3", "/p/a.swift")])
        #expect(pieces == [.thread([.edit([edit("1", "/p/a.swift")]), .quiet([read("2")]), .edit([edit("3", "/p/a.swift")])])])
    }

    @Test func aPlanBreaksTheThread() {
        let plan = TranscriptMessage(id: "2", role: .tool, text: "Plan", toolName: "ExitPlanMode", toolUseID: "2", plan: "# Plan")
        let pieces = StepRunLayout.pieces(for: [read("1"), plan, read("3")])
        #expect(pieces == [.thread([.quiet([read("1")])]), .plan(plan), .thread([.quiet([read("3")])])])
    }

    /// A thread's id is its first step's, so it keeps its place and its
    /// open lines as more steps join it.
    @Test func aThreadKeepsItsIDAsItGrows() {
        let short = StepRunLayout.pieces(for: [read("1")])
        let long = StepRunLayout.pieces(for: [read("1"), edit("2", "/p/a.swift"), command("3")])
        #expect(short.map(\.id) == long.map(\.id))
    }

    @Test func toDoListUpdatesAreNotTurns() {
        let todo = TranscriptMessage(id: "1", role: .tool, text: "Updating its to-do list", toolName: "TodoWrite", toolUseID: "1")
        let task = TranscriptMessage(id: "2", role: .tool, text: "Updating its to-do list", toolName: "TaskUpdate", toolUseID: "2")
        #expect(TranscriptTurn.group([todo, task]).isEmpty)
        let turns = TranscriptTurn.group([todo, read("3"), task])
        #expect(turns.count == 1)
        guard case .steps(let steps) = turns.first?.kind else {
            Issue.record("expected a run of steps")
            return
        }
        #expect(steps.map(\.id) == ["3"])
    }
}
