import Foundation
import Testing
@testable import Bench

/// Bench's tool hooks, run in a shell the way Claude Code runs them: a
/// subagent working in the background mustn't hide a question Claude is
/// asking you.
struct ClaudeHooksTests {
    private func command(_ event: String) throws -> String {
        let hooks = try #require(ClaudeProvider.hooks["hooks"] as? [String: Any])
        let groups = try #require(hooks[event] as? [[String: Any]])
        let first = try #require(groups.first?["hooks"] as? [[String: Any]])
        return try #require(first.first?["command"] as? String)
    }

    /// Runs a hook with `input` on stdin against a fresh state file that
    /// says `state`, after a tool file that says `tool`.
    private func run(_ event: String, input: String, state: String, tool: String,
                     shell: String = "/bin/sh") throws -> (state: String, tool: String) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bench-hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let stateFile = folder.appendingPathComponent("tab")
        try Data(state.utf8).write(to: stateFile)
        try Data(tool.utf8).write(to: stateFile.appendingPathExtension("tool.json"))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", try command(event)]
        process.environment = ["BENCH_STATE_FILE": stateFile.path, "PATH": "/usr/bin:/bin"]
        let stdin = Pipe()
        process.standardInput = stdin
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return (try String(contentsOf: stateFile, encoding: .utf8),
                try String(contentsOf: stateFile.appendingPathExtension("tool.json"), encoding: .utf8))
    }

    private let question = #"{"tool_name":"AskUserQuestion","tool_input":{"questions":[]},"hook_event_name":"PreToolUse"}"#
    private let subagentBash = #"{"session_id":"s","agent_id":"a1","agent_type":"Explore","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}"#
    private let mainBash = #"{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo \"agent_id\": hi"}}"#

    @Test(arguments: ["/bin/sh", "/bin/zsh", "/bin/bash"])
    func aSubagentLeavesAQuestionOnScreen(shell: String) throws {
        let before = try run("PreToolUse", input: subagentBash, state: "waiting", tool: question, shell: shell)
        #expect(before.tool == question)
        let after = try run("PostToolUse", input: subagentBash, state: "waiting", tool: question, shell: shell)
        #expect(after.state == "waiting")
    }

    @Test func aPlanApprovalStaysUpToo() throws {
        let plan = #"{"tool_name":"ExitPlanMode","tool_input":{}}"#
        #expect(try run("PostToolUse", input: subagentBash, state: "waiting", tool: plan).state == "waiting")
    }

    @Test func theMainConversationStillMovesOn() throws {
        // Answering the question: Claude's own PostToolUse means it's working again.
        #expect(try run("PostToolUse", input: question, state: "waiting", tool: question).state == "working")
        // "agent_id" inside a command's text isn't a subagent.
        let next = try run("PreToolUse", input: mainBash, state: "waiting", tool: question)
        #expect(next.tool == mainBash)
    }

    @Test func aSubagentOutsideAQuestionIsRecordedAsBefore() throws {
        // A subagent's permission prompt: approving it means work goes on.
        let bash = #"{"tool_name":"Bash","tool_input":{"command":"ls"}}"#
        #expect(try run("PostToolUse", input: subagentBash, state: "waiting", tool: bash).state == "working")
        // Background work after Claude's turn ended.
        #expect(try run("PostToolUse", input: subagentBash, state: "done", tool: bash).state == "working")
        #expect(try run("PreToolUse", input: subagentBash, state: "working", tool: bash).tool == subagentBash)
    }
}
