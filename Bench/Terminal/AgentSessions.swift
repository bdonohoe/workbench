import BenchKit
import Foundation

/// Lets agent tabs pick up their conversation after Bench quits and reopens,
/// and keeps track of what each one is doing.
///
/// An agent tab starts its agent with hooks (the tab's `AgentProvider`
/// decides which) that record the current session in a file per tab
/// (`claude-sessions/<tab id>.json`). The hook for a session starting
/// rewrites it on start, `/clear`, and `/resume`. The one for a session
/// ending deletes it when you exit the agent yourself, so only sessions
/// that were still open come back.
///
/// The same hooks report what the agent is doing. They write one word
/// ("working", "waiting", or "done") to `claude-state/<tab id>`, which
/// `AgentStateWatcher` picks up. That's how Bench tells "waiting for your
/// permission" apart from "finished". For the Overview, a few hooks also save
/// the agent's own JSON for that event as `<tab id>.<event>.json`: your prompt,
/// the tool it's about to run, its permission question, and when it stops.
///
/// The folders are named for Claude because they were Claude's first.
/// Renaming them would orphan the sessions of everyone who updates.
enum AgentSessions {
    private static let support = BenchPaths.support
    private static let sessionsFolder = support.appendingPathComponent("claude-sessions")
    static let stateFolder = support.appendingPathComponent("claude-state")
    /// Which `bench` commands this copy of Workbench has, and what to
    /// tell a session that started under a copy with different ones.
    private static let commandsFile = support.appendingPathComponent("bench-commands")

    /// Leaves the running app's `bench` commands where every Claude tab's
    /// hook can compare them with what its session was told at the start.
    /// Sessions outlive app updates, so without this a long-running one
    /// goes on describing a Workbench that has since changed.
    static func publishCommands() {
        let text = BenchCommand.version + "\n" + BenchCommand.changedNotice + "\n"
        if (try? String(contentsOf: commandsFile, encoding: .utf8)) != text {
            try? text.write(to: commandsFile, atomically: true, encoding: .utf8)
        }
    }

    /// What the agent is told about where it's running, so "start an agent
    /// on this" works without explaining the tool first. It's made from
    /// the table of commands, and points at `bench help` for the rest.
    static var benchNote: String { BenchCommand.note }

    /// The command typed into a new agent tab's shell, and the environment
    /// it needs. A non-main account goes in through its own variable, typed
    /// in front of the command so a shell profile that sets it can't win.
    static func launch(tabID: UUID, folder: String, prompt: String?, resuming pastSession: String? = nil,
                       account: ClaudeProfile = .main(), agentAccount: UUID? = nil,
                       provider: any AgentProvider = Agents.standard) -> (input: String, environment: [String: String]) {
        let sessionFile = sessionsFolder.appendingPathComponent("\(tabID.uuidString).json")
        let stateFile = stateFolder.appendingPathComponent(tabID.uuidString)
        // State and events left over from before Bench quit no longer apply.
        let leftovers = (try? FileManager.default.contentsOfDirectory(at: stateFolder, includingPropertiesForKeys: nil)) ?? []
        for file in leftovers where file.lastPathComponent.hasPrefix(tabID.uuidString) {
            try? FileManager.default.removeItem(at: file)
        }
        try? FileManager.default.createDirectory(at: sessionsFolder, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: stateFolder, withIntermediateDirectories: true)

        // The note and the prompt go in through the environment, not typed
        // out (see `AgentLaunch.Start.prompt`).
        var environment = ["BENCH_SESSION_FILE": sessionFile.path, "BENCH_STATE_FILE": stateFile.path,
                           "BENCH_NOTE": benchNote,
                           // What the note described, for the hook that notices when it's out of date.
                           "BENCH_COMMANDS": BenchCommand.version]
        let start: AgentLaunch.Start
        if let pastSession {
            start = .resume(session: pastSession)
        } else if let id = resumableSession(at: sessionFile) {
            start = .resume(session: id)
        } else if let prompt {
            environment["BENCH_PROMPT"] = prompt
            start = .prompt(variable: "BENCH_PROMPT")
        } else {
            start = .fresh
        }
        let base = provider.command()
        var command = provider.accountPrefix(claude: account, agentAccount: agentAccount) + base
        command += provider.launchArguments(for: AgentLaunch(tabID: tabID, folder: folder, start: start, account: account, noteVariable: "BENCH_NOTE"),
                                            environment: &environment)
        // Explain a missing program instead of leaving only the shell's
        // "command not found". Works in zsh, bash, and fish.
        // Only for the agent's own program: a wrapper the user named may
        // live anywhere, and its failures are its own.
        if base.split(separator: " ").first.map(String.init) == provider.program, Tools.path(provider.program) == nil {
            command += #" || printf '\n%s\n' "# + shellQuote(provider.missingProgramNote)
        }
        #if DEBUG
        // BENCH_FAKE_CLAUDE=1 makes agent tabs print a line instead of
        // starting the agent, for layout checks on copied projects. A path
        // to a script runs that instead, for load tests (LoadTestHooks).
        if let fake = ProcessInfo.processInfo.environment["BENCH_FAKE_CLAUDE"] {
            if FileManager.default.isExecutableFile(atPath: fake) { return ("exec \(shellQuote(fake))\n", environment) }
            return ("echo 'Claude tab (BENCH_FAKE_CLAUDE)'\n", environment)
        }
        #endif
        return (command + "\n", environment)
    }

    /// Which tab each open Claude session is in, by session id.
    static func openSessions() -> [String: UUID] {
        let files = (try? FileManager.default.contentsOfDirectory(at: sessionsFolder, includingPropertiesForKeys: nil)) ?? []
        var result: [String: UUID] = [:]
        for file in files {
            guard let tab = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  let data = try? Data(contentsOf: file),
                  let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = info["session_id"] as? String else { continue }
            result[id] = tab
        }
        return result
    }

    /// Lets the next model switch in this tab skip Claude's confirmation,
    /// for a minute. See the PreModelSwitch hook.
    static func allowModelSwitch(tabID: UUID) {
        let marker = stateFolder.appendingPathComponent("\(tabID.uuidString).model-ok")
        try? Data().write(to: marker, options: .atomic)
    }

    /// True while Claude is running in the tab: its SessionStart hook wrote
    /// the record and its SessionEnd hook hasn't removed it.
    static func isRunning(tabID: UUID) -> Bool {
        FileManager.default.fileExists(atPath: sessionsFolder.appendingPathComponent("\(tabID.uuidString).json").path)
    }

    /// The transcript of the session running in a tab, from its record.
    static func transcriptPath(tabID: UUID) -> String? {
        let file = sessionsFolder.appendingPathComponent("\(tabID.uuidString).json")
        guard let data = try? Data(contentsOf: file),
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return info["transcript_path"] as? String
    }

    /// The model the tab's session started with, like "claude-opus-5-5".
    /// Claude Code leaves it out when resuming.
    static func startModel(tabID: UUID) -> String? {
        let file = sessionsFolder.appendingPathComponent("\(tabID.uuidString).json")
        guard let data = try? Data(contentsOf: file),
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return info["model"] as? String
    }

    /// True when the tab has a conversation to pick back up.
    static func hasResumableSession(tabID: UUID) -> Bool {
        resumableSession(at: sessionsFolder.appendingPathComponent("\(tabID.uuidString).json")) != nil
    }

    /// The session recorded for this tab, if its conversation is still on disk.
    private static func resumableSession(at file: URL) -> String? {
        guard let data = try? Data(contentsOf: file),
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = info["session_id"] as? String, !id.isEmpty else { return nil }
        // A session where nothing was ever sent has no transcript and can't be resumed.
        if let transcript = info["transcript_path"] as? String,
           !FileManager.default.fileExists(atPath: transcript) { return nil }
        return id
    }

    /// Deletes records for tabs that no longer exist.
    static func prune(keeping tabIDs: Set<UUID>) {
        let keep = Set(tabIDs.map { "\($0.uuidString).json" })
        let files = (try? FileManager.default.contentsOfDirectory(at: sessionsFolder, includingPropertiesForKeys: nil)) ?? []
        for file in files where !keep.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
        let keepStates = Set(tabIDs.map(\.uuidString))
        let states = (try? FileManager.default.contentsOfDirectory(at: stateFolder, includingPropertiesForKeys: nil)) ?? []
        // Files are "<tab id>" or "<tab id>.<event>.json".
        for file in states where !keepStates.contains(String(file.lastPathComponent.prefix(36))) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
