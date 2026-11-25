import Foundation
import Testing
@testable import BenchKit

/// The files a turn changed, put together from its edits.
@Suite struct TurnChangesTests {
    // MARK: Building a conversation

    private func prompt(_ id: String, _ text: String = "Do it") -> TranscriptMessage {
        TranscriptMessage(id: id, role: .user, text: text)
    }

    private func reply(_ id: String) -> TranscriptMessage {
        TranscriptMessage(id: id, role: .assistant, text: "Done.")
    }

    /// An Edit call and its result, with the patch Claude Code saved.
    private func edit(_ id: String, _ path: String, added: Int = 1, removed: Int = 1, new: Bool = false, failed: Bool = false,
                      start: Int = 10) -> [TranscriptMessage] {
        let call = TranscriptMessage(id: id, role: .tool, text: "Editing", detail: path, toolName: new ? "Write" : "Edit",
                                     edit: ToolEdit(removed: [], added: [], removedCount: removed, addedCount: added, isNewFile: new),
                                     toolUseID: "use-" + id)
        let lines = (0..<removed).map { "-old \($0)" } + (0..<added).map { "+new \($0)" }
        let patch = EditPatch(path: path, isNewFile: new, hunks: [EditPatch.Hunk(oldStart: new ? 0 : start, newStart: new ? 1 : start, lines: lines)],
                              additions: added, deletions: removed)
        let result = TranscriptMessage(id: id + "/result", role: .tool, text: failed ? "String to replace not found" : "ok",
                                       resultOf: "use-" + id, isError: failed, patch: failed ? nil : patch)
        return [call, result]
    }

    private func bash(_ id: String, _ command: String) -> TranscriptMessage {
        TranscriptMessage(id: id, role: .tool, text: "Running", detail: command, toolName: "Bash", toolUseID: "use-" + id)
    }

    private func changes(_ messages: [TranscriptMessage]) -> [TurnChanges] {
        TurnChanges.all(in: TranscriptTurn.group(messages))
    }

    // MARK: Turns

    @Test func aTurnRunsFromOnePromptToTheNext() {
        let turns = changes([prompt("p1")] + edit("e1", "/repo/A.swift", added: 3, removed: 1) + [reply("a1"), prompt("p2")]
                            + edit("e2", "/repo/B.swift", added: 2, removed: 0) + [reply("a2")])
        #expect(turns.map(\.id) == ["p1", "p2"])
        #expect(turns[0].files.map(\.path) == ["/repo/A.swift"])
        #expect(turns[0].lastRowID == "a1")
        #expect(turns[0].isLatest == false)
        #expect(turns[1].files.map(\.path) == ["/repo/B.swift"])
        #expect(turns[1].lastRowID == "a2")
        #expect(turns[1].isLatest == true)
        #expect(turns[0].additions == 3)
        #expect(turns[0].deletions == 1)
    }

    @Test func aTurnThatEditsNothingIsLeftOutButCanBeTheLatest() {
        let messages = [prompt("p1")] + edit("e1", "/repo/A.swift") + [reply("a1"), prompt("p2"), reply("a2")]
        let grouped = TranscriptTurn.group(messages)
        #expect(TurnChanges.all(in: grouped).map(\.id) == ["p1"])
        let latest = TurnChanges.latest(in: grouped)
        #expect(latest?.id == "p2")
        #expect(latest?.files.isEmpty == true)
        #expect(TurnChanges.turn("p1", in: grouped)?.files.count == 1)
        #expect(TurnChanges.turn("gone", in: grouped) == nil)
        #expect(TurnChanges.latest(in: []) == nil)
    }

    @Test func theCardGoesUnderTheLastRowEvenWhenItIsTheSteps() {
        let turns = changes([prompt("p1")] + edit("e1", "/repo/A.swift"))
        #expect(turns.first?.lastRowID == "steps-e1")
    }

    @Test func yourOwnCommandsDoNotStartATurn() {
        let shell = TranscriptMessage(id: "s1", role: .user, text: "! ls", shell: ShellRun(command: "ls", stdout: "a", stderr: ""))
        let turns = changes([prompt("p1")] + edit("e1", "/repo/A.swift") + [shell] + edit("e2", "/repo/B.swift") + [reply("a1")])
        #expect(turns.count == 1)
        #expect(turns[0].files.map(\.path) == ["/repo/A.swift", "/repo/B.swift"])
        #expect(turns[0].ranShell == false)
    }

    @Test func aConversationReadFromPartWayStillHasItsFirstTurn() {
        let turns = changes(edit("e1", "/repo/A.swift") + [reply("a1"), prompt("p2")])
        #expect(turns.map(\.id) == ["before-steps-e1"])
        #expect(turns[0].lastRowID == "a1")
    }

    @Test func queuedMessagesAreNotTurnsYet() {
        var waiting = prompt("q1", "And then this")
        waiting.queue = .added
        let turns = changes([prompt("p1")] + edit("e1", "/repo/A.swift") + [waiting] + edit("e2", "/repo/B.swift"))
        #expect(turns.count == 1)
        #expect(turns[0].files.count == 2)
    }

    // MARK: Files

    @Test func editsToOneFileFoldTogetherInFirstTouchedOrder() {
        let turns = changes([prompt("p1")] + edit("e1", "/repo/A.swift", added: 2, removed: 1, start: 5) + edit("e2", "/repo/B.swift")
                            + edit("e3", "/repo/A.swift", added: 4, removed: 0, start: 40))
        let files = turns[0].files
        #expect(files.map(\.path) == ["/repo/A.swift", "/repo/B.swift"])
        #expect(files[0].additions == 6)
        #expect(files[0].deletions == 1)
        #expect(files[0].edits == 2)
        #expect(files[0].hunks.map(\.newStart) == [5, 40])
        #expect(files[0].isNewFile == false)
    }

    @Test func aFileMadeThenEditedStaysNew() {
        let turns = changes([prompt("p1")] + edit("e1", "/repo/New.swift", added: 10, removed: 0, new: true) + edit("e2", "/repo/New.swift"))
        #expect(turns[0].files[0].isNewFile == true)
        #expect(turns[0].files[0].additions == 11)
    }

    @Test func failedEditsChangeNothing() {
        let turns = changes([prompt("p1")] + edit("e1", "/repo/A.swift", failed: true) + edit("e2", "/repo/B.swift"))
        #expect(turns[0].files.map(\.path) == ["/repo/B.swift"])
        #expect(changes([prompt("p1")] + edit("e1", "/repo/A.swift", failed: true)).isEmpty)
    }

    @Test func withoutPatchesTheCallsCountsAndFirstLinesAreUsed() {
        let call = TranscriptMessage(id: "e1", role: .tool, text: "Editing", detail: "/repo/A.swift", toolName: "Edit",
                                     edit: ToolEdit(removed: ["a"], added: ["b", "c"], removedCount: 1, addedCount: 20, isNewFile: false),
                                     toolUseID: "use-e1")
        let file = changes([prompt("p1"), call])[0].files[0]
        #expect(file.additions == 20)
        #expect(file.deletions == 1)
        #expect(file.hunks == [EditPatch.Hunk(oldStart: 0, newStart: 0, lines: ["-a", "+b", "+c"])])
        #expect(file.truncated == true)
    }

    @Test func aFileWrittenFromTheShellCountsAsAWrite() throws {
        let command = "cat > /repo/Notes.md <<'EOF'\none\ntwo\nEOF"
        let line = try JSONSerialization.data(withJSONObject: [
            "type": "assistant", "uuid": "b1",
            "message": ["content": [["type": "tool_use", "id": "use-b1", "name": "Bash", "input": ["command": command]]]],
        ])
        let turns = changes([prompt("p1")] + TranscriptParser.messages(in: line))
        #expect(turns[0].files.map(\.path) == ["/repo/Notes.md"])
        #expect(turns[0].files[0].isNewFile == true)
        #expect(turns[0].files[0].additions == 2)
        #expect(turns[0].ranShell == false)
    }

    @Test func aNotebookIsListedWithoutCounts() {
        let call = TranscriptMessage(id: "n1", role: .tool, text: "Editing", detail: "/repo/Plot.ipynb", toolName: "NotebookEdit", toolUseID: "use-n1")
        let file = changes([prompt("p1"), call])[0].files[0]
        #expect(file.path == "/repo/Plot.ipynb")
        #expect(file.hasCounts == false)
    }

    @Test func plansAreNotChanges() {
        let turns = changes([prompt("p1")] + edit("e1", NSHomeDirectory() + "/.claude/plans/a-plan.md", new: true))
        #expect(turns.isEmpty)
    }

    // MARK: What it can't see

    @Test func readsLeaveTheListComplete() {
        let turns = changes([prompt("p1"), bash("b1", "git status"), bash("b2", "cd /repo && grep -rn foo Sources | head")]
                            + edit("e1", "/repo/A.swift"))
        #expect(turns[0].ranShell == false)
        #expect(turns[0].incompleteNote == nil)
    }

    @Test func otherShellCommandsMayHaveChangedFiles() {
        let turns = changes([prompt("p1")] + edit("e1", "/repo/A.swift") + [bash("b1", "make build")])
        #expect(turns[0].ranShell == true)
        #expect(turns[0].incompleteNote == "Shell commands in this turn may have changed other files.")
    }

    @Test func subagentsMayHaveChangedFiles() {
        let agent = TranscriptMessage(id: "g1", role: .tool, text: "Agent", toolName: "Agent", toolUseID: "use-g1",
                                      agent: AgentCall(description: "Look around", type: nil, background: false))
        let turns = changes([prompt("p1"), agent] + edit("e1", "/repo/A.swift"))
        #expect(turns[0].ranAgents == true)
        #expect(turns[0].incompleteNote == "Subagents in this turn may have changed other files.")
        let both = changes([prompt("p1"), agent, bash("b1", "rm x")] + edit("e1", "/repo/A.swift"))
        #expect(both[0].incompleteNote == "Shell commands and subagents in this turn may have changed other files.")
    }

    @Test func notesNeverUseADash() {
        for (shell, agents) in [(true, true), (true, false), (false, true)] {
            var turn = TurnChanges(id: "p", lastRowID: "p")
            turn.ranShell = shell
            turn.ranAgents = agents
            #expect(turn.incompleteNote?.contains("\u{2014}") == false)
        }
    }

    // MARK: Paths

    @Test func pathsAreShownByTheirPlaceInTheProject() {
        #expect(TurnChanges.shownPath("/repo/Sources/A.swift", root: "/repo") == "Sources/A.swift")
        #expect(TurnChanges.shownPath("/repo/Sources/A.swift", root: "/repo/") == "Sources/A.swift")
        #expect(TurnChanges.shownPath("/repo.worktrees/x/A.swift", root: "/repo") == "/repo.worktrees/x/A.swift")
        #expect(TurnChanges.shownPath(NSHomeDirectory() + "/notes/a.md", root: "/repo") == "~/notes/a.md")
        #expect(TurnChanges.shownPath("/repo/A.swift", root: nil) == "/repo/A.swift")
        // The same folder by two names, where it's really there to check.
        #expect(TurnChanges.shownPath("/tmp/A.swift", root: "/private/tmp") == "A.swift")
    }

    // MARK: As a review

    @Test func aTurnReadsAsAReview() {
        let hunks = [EditPatch.Hunk(oldStart: 4, newStart: 4, lines: [" a", "-b", "+B", " c"]),
                     EditPatch.Hunk(oldStart: 30, newStart: 30, lines: ["+z"])]
        var turn = TurnChanges(id: "p", lastRowID: "p")
        turn.files = [
            TurnChanges.File(path: "/repo/Sources/A.swift", isNewFile: false, additions: 2, deletions: 1, hasCounts: true, edits: 2, hunks: hunks, truncated: false),
            TurnChanges.File(path: "/repo/New.swift", isNewFile: true, additions: 1, deletions: 0, hasCounts: true, edits: 1,
                             hunks: [EditPatch.Hunk(oldStart: 0, newStart: 1, lines: ["+hello"])], truncated: true),
        ]
        let diff = ReviewDiff(turn: turn, root: "/repo")
        #expect(diff.files.map(\.path) == ["Sources/A.swift", "New.swift"])
        #expect(diff.files.map(\.status) == ["M", "A"])
        #expect(diff.files[0].headerLine == 0)
        #expect(diff.lines[0].text == "Sources/A.swift  +2 −1")
        #expect(diff.lines.map(\.id) == Array(diff.lines.indices))
        let first = Array(diff.lines[diff.lineRange(ofFileAt: 0)])
        #expect(first.map(\.kind) == [.context, .removed, .added, .context, .hunk, .added])
        #expect(first.map(\.oldNumber) == [4, 5, nil, 6, nil, nil])
        #expect(first.map(\.newNumber) == [4, nil, 5, 6, nil, 30])
        #expect(first[1].text == "b")
        #expect(!first[1].segments.isEmpty || first[1].text.count == 1)
        let second = Array(diff.lines[diff.lineRange(ofFileAt: 1)])
        #expect(second.map(\.kind) == [.added, .meta])
        #expect(second[0].newNumber == 1)
    }

    @Test func linesWithoutNumbersStayUnnumbered() {
        var turn = TurnChanges(id: "p", lastRowID: "p")
        turn.files = [TurnChanges.File(path: "/repo/A.swift", isNewFile: false, additions: 1, deletions: 1, hasCounts: true, edits: 1,
                                       hunks: [EditPatch.Hunk(oldStart: 0, newStart: 0, lines: ["-a", "+b"])], truncated: false)]
        let diff = ReviewDiff(turn: turn, root: nil)
        #expect(diff.lines.dropFirst().allSatisfy { $0.oldNumber == nil && $0.newNumber == nil })
    }
}
