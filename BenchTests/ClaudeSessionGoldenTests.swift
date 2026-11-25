import BenchKit
import Foundation
import Testing
@testable import Bench

/// How Workbench starts Claude and follows it through hooks, pinned to
/// what it does today.
@MainActor
struct ClaudeLaunchGoldenTests {
    /// The launch with this Mac's details taken out: the support folder,
    /// the note (which changes whenever a `bench` command does), and the
    /// parts that depend on what's installed or set here.
    private func launch(prompt: String? = nil, resuming: String? = nil, account: ClaudeProfile = .main()) -> String {
        // Your own launch command and status line would change the result.
        let saved = UserDefaults.standard.string(forKey: Agents.claude.commandKey)
        UserDefaults.standard.removeObject(forKey: Agents.claude.commandKey)
        defer { if let saved { UserDefaults.standard.set(saved, forKey: Agents.claude.commandKey) } }

        let tab = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bench-launch-\(UUID().uuidString)")
        let started = AgentSessions.launch(tabID: tab, folder: folder.path, prompt: prompt, resuming: resuming, account: account)
        func plain(_ text: String) -> String {
            text.replacingOccurrences(of: BenchPaths.support.path, with: "<support>")
        }
        var input = plain(started.input)
        // Added only when Claude Code isn't installed.
        if let range = input.range(of: " || printf ") { input = String(input[..<range.lowerBound]) + "\n" }
        var environment = started.environment
        environment["BENCH_NOTE"] = environment["BENCH_NOTE"] == BenchCommand.note ? "<the bench note>" : "?"
        environment["BENCH_COMMANDS"] = environment["BENCH_COMMANDS"] == BenchCommand.version ? "<the commands version>" : "?"
        environment["BENCH_USER_STATUS_LINE"] = nil
        let lines = environment.keys.sorted().map { "\($0)=\(plain(environment[$0]!))" }
        return "types: \(input)" + lines.joined(separator: "\n") + "\n"
    }

    @Test func theCommandAClaudeTabTypes() throws {
        let second = ClaudeProfile(id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!, name: "Work", folder: "~/.claude-work")
        let text = """
            # A new tab
            \(launch())
            # A new tab with a prompt
            \(launch(prompt: "Fix the login crash"))
            # Picking a past session back up
            \(launch(resuming: "0a1b2c3d-past-session"))
            # A second account
            \(launch(prompt: "It's a prompt", account: second))
            """
        try Golden.check(text, "claude/launch.txt")
    }

    @Test func theSettingsFileItPassesToClaude() throws {
        let data = try JSONSerialization.data(withJSONObject: ClaudeProvider.hooks, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try Golden.check(String(decoding: data, as: UTF8.self) + "\n", "claude/hooks-settings.json")
    }
}

/// Every hook payload from a recorded session, put through Workbench's
/// real hook commands in a shell, the way Claude Code runs them. After
/// each one, what the tab's state says and what the watcher reads back.
@MainActor
struct ClaudeHookReplayGoldenTests {
    /// What a payload is matched against, per event, when a hook has a matcher.
    private func matched(_ event: String, _ payload: [String: Any]) -> String {
        switch event {
        case "PreToolUse", "PostToolUse": payload["tool_name"] as? String ?? ""
        case "Notification": payload["notification_type"] as? String ?? ""
        case "SessionEnd": payload["reason"] as? String ?? ""
        case "SessionStart": payload["source"] as? String ?? ""
        default: ""
        }
    }

    /// Runs the event's hooks from `ClaudeProvider.hooks` on one payload.
    private func fire(_ payload: [String: Any], environment: [String: String]) throws {
        let event = try #require(payload["hook_event_name"] as? String)
        let hooks = try #require(ClaudeProvider.hooks["hooks"] as? [String: Any])
        let input = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
        for group in hooks[event] as? [[String: Any]] ?? [] {
            if let matcher = group["matcher"] as? String,
               matched(event, payload).wholeMatch(of: try Regex(matcher)) == nil { continue }
            for hook in group["hooks"] as? [[String: Any]] ?? [] {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", try #require(hook["command"] as? String)]
                process.environment = environment
                let stdin = Pipe()
                process.standardInput = stdin
                process.standardOutput = FileHandle.nullDevice
                try process.run()
                stdin.fileHandleForWriting.write(input)
                try stdin.fileHandleForWriting.close()
                process.waitUntilExit()
            }
        }
    }

    @Test(arguments: ["tools", "interactive"])
    func aRecordedSessionsHooks(session: String) throws {
        let text = try HookReplay.run(try Golden.entries("claude/hooks/\(session).jsonl"), named: session) { payload, environment in
            try fire(payload, environment: environment)
        }
        try Golden.check(text, "claude/\(session).hooks.txt")
    }
}
