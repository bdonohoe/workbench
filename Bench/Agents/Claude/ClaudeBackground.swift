import BenchKit
import Foundation

/// Claude Code run out of sight: `claude -p`, and `claude auth status`.
nonisolated struct ClaudeBackground: AgentBackground {
    var agent: AgentID { .claude }
    var program: String { "claude" }

    func oneShot(instructions: String, model: BackgroundModel, profile: ClaudeProfile) -> BackgroundCommand {
        let name = switch model { case .small: "haiku" }
        var command = BackgroundCommand(arguments: [
            "-p", "--model", name, "--no-session-persistence", "--tools", "",
            "--strict-mcp-config", "--setting-sources", "", "--system-prompt", instructions,
            "--output-format", "json"])
        // The main account leaves this alone, as it does in a terminal tab.
        if let folder = profile.folder { command.environment["CLAUDE_CONFIG_DIR"] = folder }
        // Each call is a one-off, so nothing would ever read the cache back,
        // and writing to it costs up to twice as much as plain input.
        command.environment["DISABLE_PROMPT_CACHING"] = "1"
        return command
    }

    func oneShotReply(in output: String) -> BackgroundReply? { BackgroundReply.parse(output) }

    func sideQuestion(_ prompt: String, sessionID: String, model: String?, profile: ClaudeProfile) -> BackgroundCommand {
        var arguments = ["-p", "--resume", sessionID, "--fork-session", "--no-session-persistence",
                         "--settings", #"{"disableAllHooks":true}"#, "--permission-mode", "dontAsk", "--max-turns", "1",
                         "--output-format", "stream-json", "--include-partial-messages", "--verbose"]
        if let model { arguments += ["--model", model] }
        arguments.append(prompt)
        // Set when Workbench itself was started from Claude Code, which
        // would turn off saving and so leave nothing to resume.
        var command = BackgroundCommand(arguments: arguments,
                                        removing: ["CLAUDECODE", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_ENTRYPOINT"])
        if let config = profile.folder { command.environment["CLAUDE_CONFIG_DIR"] = config }
        return command
    }

    func sideQuestionEvent(in line: String) -> SideQuestionStream.Event? { SideQuestionStream.event(in: line) }

    func startsToolCall(_ line: String) -> Bool { SideQuestionStream.startsToolCall(line) }

    /// Runs `claude auth status` in the login shell.
    func signInStatus(program path: String, folder: String?) -> ClaudeAccount.Status? {
        let prefix = folder.map { "CLAUDE_CONFIG_DIR=\(ClaudeProfile.quote($0)) " } ?? ""
        guard let output = Tools.runInShell("\(prefix)\(ClaudeProfile.quote(path)) auth status --json", requireSuccess: false) else { return nil }
        return ClaudeAccount.Status.parse(output)
    }

    var planLimits: (any AgentPlanLimits)? { ClaudePlanLimits() }

    func tally(usage: [String: Any], model: String) -> UsageTally { UsageLedger.tally(usage: usage, model: model) }
}
