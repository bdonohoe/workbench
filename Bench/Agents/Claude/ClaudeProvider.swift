import BenchKit
import Foundation

/// Claude Code.
///
/// A Claude tab starts Claude with a small settings file whose hooks
/// record the tab's session and report what Claude is doing (see
/// `AgentSessions`). The same file sets a status line that passes the
/// plan's usage on to `PlanUsageMonitor`.
struct ClaudeProvider: AgentProvider {
    let id = AgentID.claude
    let name = "Claude"
    let productName = "Claude Code"
    let symbol = "sparkle"
    let program = "claude"
    /// Settings > Claude: what new Claude tabs run in place of plain `claude`,
    /// like `claude --permission-mode acceptEdits` or a wrapper script.
    let commandKey = "claudeCommand"
    let missingProgramNote = "Workbench could not find Claude Code. Install it from https://claude.com/product/claude-code then open a new Claude tab."

    func accountPrefix(claude: ClaudeProfile, agentAccount: UUID?) -> String { claude.shellPrefix }

    nonisolated var driver: any AgentTerminalDriver { ClaudeTerminalDriver() }
    var catalog: AgentCatalog { .claude }
    nonisolated func savedEffort(forModel model: String?) -> String? { ClaudeEffort.saved(forModel: model) }
    nonisolated var background: any AgentBackground { ClaudeBackground() }
    nonisolated var transcripts: any AgentTranscripts { ClaudeTranscripts() }

    private static let hooksFile = BenchPaths.support.appendingPathComponent("claude-hooks.json")

    func launchArguments(for launch: AgentLaunch, environment: inout [String: String]) -> String {
        var arguments = ""
        let userStatusLine = Self.userStatusLine(in: launch.folder, account: launch.account)
        do {
            let data = try JSONSerialization.data(withJSONObject: Self.settings(userStatusLine: userStatusLine), options: [.prettyPrinted, .sortedKeys])
            if (try? Data(contentsOf: Self.hooksFile)) != data { try data.write(to: Self.hooksFile, options: .atomic) }
            arguments += " --settings \(shellQuote(Self.hooksFile.path))"
        } catch {
            NSLog("Bench: couldn't set up Claude session tracking: \(error)")
        }
        arguments += #" --append-system-prompt "$\#(launch.noteVariable)""#
        switch launch.start {
        case .fresh: break
        case .prompt(let variable): arguments += #" "$\#(variable)""#
        case .resume(let session): arguments += " --resume \(shellQuote(session))"
        }
        environment["BENCH_STATUS_FILE"] = launch.account.statusFile.path
        if let own = userStatusLine?["command"] as? String, !own.isEmpty {
            environment["BENCH_USER_STATUS_LINE"] = own
        }
        return arguments
    }

    // MARK: Hooks

    /// Subagents run the tab's hooks too, and keep working in the
    /// background while Claude asks you something. Their tool calls would
    /// replace the question's tool file and mark the tab working, and the
    /// chat view would drop the question. So a subagent's call (Claude Code
    /// adds `agent_id` only for those) does nothing while the tab waits on
    /// a question or a plan approval.
    private static func ignoringSubagentsDuringPicker(_ hook: [String: Any]) -> [String: Any] {
        guard let command = hook["command"] as? String else { return hook }
        var wrapped = hook
        wrapped["command"] = #"input=$(cat); case "$input" in *'"agent_id":'*) if [ "$(cat "$BENCH_STATE_FILE" 2>/dev/null)" = waiting ] && grep -Eq '"tool_name": *"(AskUserQuestion|ExitPlanMode)"' "$BENCH_STATE_FILE.tool.json" 2>/dev/null; then exit 0; fi ;; esac; printf '%s' "$input" | { "#
            + command + "; }"
        return wrapped
    }

    /// Claude Code hands its status line command the plan's 5-hour and
    /// weekly usage. This one saves that for `PlanUsageMonitor` (only when
    /// it has the numbers), then runs your own status line, if you have
    /// one, so the terminal looks the same as it does without Bench.
    private static let statusLineCommand =
        #"input=$(cat); case "$input" in *'"rate_limits"'*) if [ -n "$BENCH_STATUS_FILE" ]; then printf '%s' "$input" > "$BENCH_STATUS_FILE.$$" && mv -f "$BENCH_STATUS_FILE.$$" "$BENCH_STATUS_FILE"; fi ;; esac; if [ -n "$BENCH_USER_STATUS_LINE" ]; then printf '%s' "$input" | /bin/bash -c "$BENCH_USER_STATUS_LINE"; fi"#

    /// Bench's settings for a Claude tab: its hooks, plus a status line
    /// that keeps the user's own padding.
    private static func settings(userStatusLine: [String: Any]?) -> [String: Any] {
        var settings = hooks
        var statusLine: [String: Any] = ["type": "command", "command": statusLineCommand]
        if let padding = userStatusLine?["padding"] { statusLine["padding"] = padding }
        settings["statusLine"] = statusLine
        return settings
    }

    /// The status line Claude would use in `folder` without Bench: the
    /// project's local settings, then the project's, then the account's.
    static func userStatusLine(in folder: String, account: ClaudeProfile) -> [String: Any]? {
        let home = account.isMain
            ? ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) } ?? account.configURL
            : account.configURL
        let project = URL(fileURLWithPath: folder).appendingPathComponent(".claude")
        let files = [project.appendingPathComponent("settings.local.json"),
                     project.appendingPathComponent("settings.json"),
                     home.appendingPathComponent("settings.json")]
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let statusLine = json["statusLine"] as? [String: Any] else { continue }
            return statusLine
        }
        return nil
    }

    private typealias Hook = AgentHookCommands

    static let hooks: [String: Any] = [
        "hooks": [
            "SessionStart": [[
                "hooks": [Hook.recordSession,
                          // Also tells the state watcher, for the model and
                          // the new transcript after /clear.
                          Hook.saveEvent("start")],
            ]],
            "SessionEnd": [[
                "matcher": "prompt_input_exit|logout",
                "hooks": [Hook.forgetSession],
            ], [
                "hooks": [Hook.clearState],
            ]],
            "UserPromptSubmit": [["hooks": [Hook.writeState(.working), Hook.saveEvent("prompt"), Hook.commandsChanged]]],
            // Runs before each tool, including before asking permission for it.
            "PreToolUse": [["hooks": [ignoringSubagentsDuringPicker(Hook.saveEvent("tool"))]], [
                // These put a picker on screen without a Notification, so
                // mark the tab as waiting for you right away.
                "matcher": "AskUserQuestion|ExitPlanMode",
                "hooks": [Hook.writeState(.waiting)],
            ]],
            // Runs after each tool, including right after you approve one.
            "PostToolUse": [["hooks": [ignoringSubagentsDuringPicker(Hook.writeState(.working))]]],
            "Notification": [[
                "matcher": "permission_prompt|elicitation_dialog",
                "hooks": [Hook.writeState(.waiting), Hook.saveEvent("question")],
            ]],
            "Stop": [["hooks": [Hook.writeState(.done), Hook.saveEvent("stop")]]],
            // Wakes Bench up to see that a subagent finished.
            "SubagentStop": [["hooks": [Hook.saveEvent("agent")]]],
            // A model switch picked in the chat view (Mac or phone) goes
            // ahead without Claude's "Switch model?" question, which only
            // its terminal could answer. The chat view asks first itself.
            // `/model` typed in the terminal still gets Claude's question.
            "PreModelSwitch": [["hooks": [Hook.command(#"m="$BENCH_STATE_FILE.model-ok"; if [ -n "$BENCH_STATE_FILE" ] && [ -n "$(find "$m" -mmin -1 2>/dev/null)" ]; then rm -f "$m"; printf '%s' '{"hookSpecificOutput":{"hookEventName":"PreModelSwitch","permissionDecision":"allow"}}'; fi"#)]]],
            // Runs right after the model changes, however it happened, so
            // the chat view shows the new one without waiting for a reply.
            // Prints nothing: what it prints would reach Claude.
            "PostModelSwitch": [["hooks": [Hook.saveEvent("model")]]],
            // Summarizing the conversation to make room, and done with it.
            "PreCompact": [["hooks": [Hook.saveEvent("compact")]]],
            "PostCompact": [["hooks": [Hook.saveEvent("compacted")]]],
        ],
    ]
}
