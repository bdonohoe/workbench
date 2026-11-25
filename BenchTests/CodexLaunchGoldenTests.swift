import BenchKit
import Foundation
import Testing
@testable import Bench

/// How Workbench starts Codex, pinned word for word. The hook settings
/// matter most: Codex asks you to review hooks it hasn't seen, so a
/// change to any of them asks everyone again.
@MainActor
struct CodexLaunchGoldenTests {
    private func launch(prompt: String? = nil, resuming: String? = nil, account: ClaudeProfile = .main()) -> String {
        let saved = UserDefaults.standard.string(forKey: Agents.codex.commandKey)
        UserDefaults.standard.removeObject(forKey: Agents.codex.commandKey)
        defer { if let saved { UserDefaults.standard.set(saved, forKey: Agents.codex.commandKey) } }

        let tab = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bench-launch-\(UUID().uuidString)")
        let started = AgentSessions.launch(tabID: tab, folder: folder.path, prompt: prompt, resuming: resuming, account: account,
                                           provider: Agents.codex)
        func plain(_ text: String) -> String { text.replacingOccurrences(of: BenchPaths.support.path, with: "<support>") }
        var input = plain(started.input)
        // Added only when Codex isn't installed.
        if let range = input.range(of: " || printf ") { input = String(input[..<range.lowerBound]) + "\n" }
        var environment = started.environment
        environment["BENCH_NOTE"] = environment["BENCH_NOTE"] == BenchCommand.note ? "<the bench note>" : "?"
        environment["BENCH_CODEX_NOTE"] = environment["BENCH_CODEX_NOTE"] == "developer_instructions=" + tomlQuote(BenchCommand.note)
            ? "developer_instructions=<the bench note, quoted>" : "?"
        environment["BENCH_COMMANDS"] = environment["BENCH_COMMANDS"] == BenchCommand.version ? "<the commands version>" : "?"
        // The hook settings are the same every time, and checked on their own below.
        for key in environment.keys where key.hasPrefix("BENCH_CODEX_") && key != "BENCH_CODEX_NOTE" { environment[key] = "<its hooks>" }
        let lines = environment.keys.sorted().map { "\($0)=\(plain(environment[$0]!))" }
        return "types: \(input)" + lines.joined(separator: "\n") + "\n"
    }

    @Test func theCommandACodexTabTypes() throws {
        let second = ClaudeProfile(id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!, name: "Work", folder: "~/.claude-work")
        let text = """
            # A new tab
            \(launch())
            # A new tab with a prompt
            \(launch(prompt: "Fix the login crash"))
            # Picking a past session back up
            \(launch(resuming: "0a1b2c3d-past-session"))
            # A second Claude account changes nothing
            \(launch(prompt: "It's a prompt", account: second))
            """
        try Golden.check(text, "codex/launch.txt")
    }

    @Test func theHookSettingsItPassesToCodex() throws {
        let text = CodexProvider.hookSettings.map { "\($0.event)\n\($0.value)\n" }.joined(separator: "\n")
        try Golden.check(text, "codex/hook-settings.txt")
    }

    @Test func theCommandFitsInWhatTheTerminalKeepsOfTypedAheadInput() {
        let started = AgentSessions.launch(tabID: UUID(), folder: "/tmp", prompt: "x", provider: Agents.codex)
        // macOS drops typed-ahead input past 1,024 bytes.
        #expect(started.input.utf8.count < 700)
    }

    @Test func quotesStringsTheWayTomlReadsThem() {
        #expect(tomlQuote(#"say "hi" \ now"#) == #""say \"hi\" \\ now""#)
        #expect(tomlQuote("two\nlines\tand a tab") == #""two\nlines\tand a tab""#)
        #expect(tomlQuote("bell\u{07}") == "\"bell\\u0007\"")
    }

    @Test func codexIsOfferedWhereItsInstalledUnlessTurnedOff() {
        let defaults = UserDefaults(suiteName: "codex-switch-\(UUID().uuidString)")!
        #expect(Agents.isOffered(.codex, defaults: defaults, installed: { _ in true }))
        #expect(!Agents.isOffered(.codex, defaults: defaults, installed: { _ in false }))
        #expect(Agents.isOffered(.claude, defaults: defaults, installed: { _ in false }))
        // Your own choice wins either way.
        defaults.set(false, forKey: Agents.codexEnabledKey)
        #expect(!Agents.isOffered(.codex, defaults: defaults, installed: { _ in true }))
        defaults.set(true, forKey: Agents.codexEnabledKey)
        #expect(Agents.isOffered(.codex, defaults: defaults, installed: { _ in false }))
        // A saved Codex tab still has its provider either way.
        #expect(Agents.provider(.codex)?.name == "Codex")
    }
}

/// Recorded Codex hook payloads, put through the commands Workbench gives
/// Codex for each event.
@MainActor
struct CodexHookReplayGoldenTests {
    @Test(arguments: ["tools", "permission", "interrupt"])
    func aRecordedSessionsHooks(session: String) throws {
        let text = try HookReplay.run(try Golden.entries("codex/hooks/\(session).jsonl"), named: session) { payload, environment in
            let event = try #require(payload["hook_event_name"] as? String)
            let input = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
            for (name, commands) in CodexProvider.hooks where name == event {
                for command in commands {
                    try HookReplay.shell(try #require(command["command"] as? String), input: input, environment: environment)
                }
            }
        }
        try Golden.check(text, "codex/\(session).hooks.txt")
    }
}

/// The hook that puts a tab back to working when a tool finishes. Codex
/// runs several commands at once, so the ones that need no permission
/// finish while another is still asking.
struct CodexParallelToolTests {
    private func run(state: String, question: String?, event: String) throws -> String {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("TAB")
        try state.write(to: file, atomically: true, encoding: .utf8)
        if let question { try question.write(to: URL(fileURLWithPath: file.path + ".question.json"), atomically: true, encoding: .utf8) }
        let script = try #require(AgentHookCommands.workingAfterTool["command"] as? String)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.environment = ["BENCH_STATE_FILE": file.path, "PATH": "/usr/bin:/bin"]
        let input = Pipe()
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(Data(event.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        return try String(contentsOf: file, encoding: .utf8)
    }

    private let asking = #"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"git switch -c x && git commit -m 'Rename \"a\" * [b]'","description":"May I?"}}"#

    @Test func aFinishedToolLeavesAnotherCommandsQuestionUp() throws {
        let other = #"{"hook_event_name":"PostToolUse","tool_input":{"command":"bench help"},"tool_response":"ok"}"#
        #expect(try run(state: "waiting", question: asking, event: other) == "waiting")
    }

    @Test func theCommandYouAllowedGoesBackToWorking() throws {
        let same = #"{"hook_event_name":"PostToolUse","tool_input":{"command":"git switch -c x && git commit -m 'Rename \"a\" * [b]'"},"tool_response":"ok"}"#
        #expect(try run(state: "waiting", question: asking, event: same) == "working")
    }

    @Test func otherwiseAFinishedToolMeansWorking() throws {
        let event = #"{"hook_event_name":"PostToolUse","tool_input":{"command":"ls"}}"#
        #expect(try run(state: "done", question: asking, event: event) == "working")
        #expect(try run(state: "waiting", question: nil, event: event) == "working")
    }
}
