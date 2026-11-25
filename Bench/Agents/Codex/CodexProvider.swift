import BenchKit
import Foundation

/// OpenAI's Codex.
///
/// Codex takes its hooks from its config file, and one launch can add to
/// that config with `-c key=value` flags. So a Codex tab is started with
/// one flag per hook event, plus one that hands it the note about `bench`.
/// Nothing is written to `~/.codex`: every flag lasts for that launch.
///
/// Codex asks you to review hooks it hasn't seen before, once, and
/// remembers the answer itself. The hook commands below never change from
/// one launch to the next (what differs per tab is in the environment), so
/// you're asked once and not again until Workbench changes them.
struct CodexProvider: AgentProvider {
    let id = AgentID.codex
    let name = "Codex"
    let productName = "Codex"
    let symbol = "hexagon"
    let program = "codex"
    /// What new Codex tabs run in place of plain `codex`.
    let commandKey = "codexCommand"
    let missingProgramNote = "Workbench could not find Codex. Install it from https://developers.openai.com/codex/cli then open a new Codex tab."
    /// Codex's accounts are `CODEX_HOME` folders (`CodexAccounts`).
    func accountPrefix(claude: ClaudeProfile, agentAccount: UUID?) -> String {
        CodexAccounts.all.first { $0.id == agentAccount }?.shellPrefix ?? ""
    }

    nonisolated var driver: any AgentTerminalDriver { CodexTerminalDriver() }
    var catalog: AgentCatalog { CodexCatalog.catalog }
    nonisolated func savedEffort(forModel model: String?) -> String? {
        (try? String(contentsOf: CodexTranscripts.home.appendingPathComponent("config.toml"), encoding: .utf8)).flatMap(CodexCatalog.savedEffort)
    }
    nonisolated var background: any AgentBackground { CodexBackground() }
    nonisolated var transcripts: any AgentTranscripts { CodexTranscripts() }

    func launchArguments(for launch: AgentLaunch, environment: inout [String: String]) -> String {
        var arguments = ""
        // Each flag's value goes in through the environment and is named
        // on the command line, for the reason the prompt is (see
        // `AgentLaunch.Start.prompt`): all of them typed out would run far
        // past what macOS keeps of typed-ahead input.
        for (event, value) in Self.hookSettings {
            let variable = "BENCH_CODEX_\(event.uppercased())"
            environment[variable] = value
            arguments += #" -c "$\#(variable)""#
        }
        if let note = environment[launch.noteVariable], !note.isEmpty {
            environment["BENCH_CODEX_NOTE"] = "developer_instructions=" + tomlQuote(note)
            arguments += #" -c "$BENCH_CODEX_NOTE""#
        }
        switch launch.start {
        case .fresh: break
        case .prompt(let variable): arguments += #" "$\#(variable)""#
        case .resume(let session): arguments += " resume \(shellQuote(session))"
        }
        return arguments
    }

    // MARK: Hooks

    private typealias Hook = AgentHookCommands

    /// Which of Workbench's commands run on which of Codex's events,
    /// in the order they're passed.
    static let hooks: [(event: String, commands: [[String: Any]])] = [
        ("SessionStart", [Hook.recordSession, Hook.saveEvent("start")]),
        // Codex gives one reason for every ending. It only reaches this
        // hook when you leave it yourself (quitting Workbench closes the
        // terminal under it), so the tab's session is forgotten here.
        ("SessionEnd", [Hook.forgetSession, Hook.clearState]),
        ("UserPromptSubmit", [Hook.writeState(.working), Hook.saveEvent("prompt"), Hook.commandsChanged]),
        ("PreToolUse", [Hook.saveEvent("tool")]),
        // Codex is asking to run something it isn't allowed to yet.
        ("PermissionRequest", [Hook.writeState(.waiting), Hook.saveEvent("question")]),
        ("PostToolUse", [Hook.workingAfterTool]),
        ("Stop", [Hook.writeState(.done), Hook.saveEvent("stop")]),
        // You stopped it, so it's your turn again.
        ("Interrupt", [Hook.writeState(.done)]),
    ]

    /// One `hooks.<Event>=[…]` setting per event, written as TOML.
    static let hookSettings: [(event: String, value: String)] = hooks.map { event, commands in
        let list = commands.compactMap { $0["command"] as? String }
            .map { "{type=\"command\",command=\(tomlQuote($0))}" }
            .joined(separator: ",")
        return (event, "hooks.\(event)=[{hooks=[\(list)]}]")
    }
}

/// What Codex offers in the chat.
enum CodexCatalog {
    /// Codex's own model list, and the effort levels both agents share.
    /// Both are set with `/model`, for the session only. The rest of the
    /// chat's extras wait on Codex reporting them through its hooks.
    nonisolated static var catalog: AgentCatalog {
        AgentCatalog(models: CodexModelList.models, efforts: EffortLevel.allCases, quickCommands: [.compact, .clear],
                     features: [.sideQuestions])
    }

    /// The effort in Codex's settings, which a new session starts with.
    /// Read only: Workbench never writes Codex's settings.
    nonisolated static func savedEffort(in config: String) -> String? {
        for line in config.components(separatedBy: "\n") {
            // Top-level keys come before the first table.
            if line.hasPrefix("[") { break }
            if let match = line.wholeMatch(of: #/\s*model_reasoning_effort\s*=\s*"([a-z]+)"\s*(#.*)?/#) { return String(match.1) }
        }
        return nil
    }
}
