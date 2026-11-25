import Foundation

/// One thing the `bench` command line tool can ask Workbench to do.
///
/// This table is the only description of the commands. `bench help`, the
/// note Claude sessions start with, and the README's list are all made
/// from it (the README by a test that fails when it falls behind), so a
/// new command is added here and nowhere else.
public struct BenchCommand: Equatable, Sendable {
    public var name: String
    /// What follows `bench <name>`, like "<agent> <message>".
    public var arguments: String
    /// One line on what it does.
    public var summary: String
    /// What someone would be asking for when this is the command to use.
    /// Written for Claude, which reads `bench help` to decide.
    public var when: String
    /// Anything else worth knowing before running it.
    public var notes: [String]
    public var examples: [String]
    /// Options that take a value, without the dashes.
    public var valueOptions: [String]
    /// Options that are on or off.
    public var flags: [String]
    /// Named in the note every Claude session starts with, since getting
    /// it wrong is costly. The rest are found through `bench help`.
    public var isHeadline: Bool
    /// Left out of help: it's for Workbench's own agents.
    public var isHidden: Bool

    public init(_ name: String, _ arguments: String = "", summary: String, when: String, notes: [String] = [],
                examples: [String] = [], valueOptions: [String] = [], flags: [String] = [], isHeadline: Bool = false,
                isHidden: Bool = false) {
        self.name = name
        self.arguments = arguments
        self.summary = summary
        self.when = when
        self.notes = notes
        self.examples = examples
        self.valueOptions = valueOptions
        self.flags = flags
        self.isHeadline = isHeadline
        self.isHidden = isHidden
    }

    /// "bench send <agent> <message>".
    public var usage: String { arguments.isEmpty ? "bench \(name)" : "bench \(name) \(arguments)" }

    public static func named(_ name: String) -> BenchCommand? {
        all.first { $0.name == name } ?? aliases[name].flatMap { alias in all.first { $0.name == alias } }
    }

    /// Other words for a command, so a near miss still works.
    public static let aliases = ["list": "projects", "agents": "status", "ps": "status", "tell": "send", "message": "send",
                                 "interrupt": "stop", "cleanup": "remove", "history": "sessions", "preview": "open",
                                 "select": "show", "focus": "show", "limits": "usage", "--help": "help", "-h": "help"]

    /// Every command, in the order help lists them.
    public static let all: [BenchCommand] = [
        // Agents
        BenchCommand("agent", "[--branch <name>] [--base <branch>] [--issue <number>] [--with <agent>] [--project <name or folder>] <prompt>",
                     summary: "Start an agent: a new git worktree on its own branch with its own agent session.",
                     when: "the user asks for agents, or for work to be done in worktrees or in parallel in Workbench",
                     notes: ["Use it once per agent, in place of your own subagents, which Workbench can't show.",
                             "The new session knows nothing of this conversation, so the prompt has to carry everything it needs.",
                             "With no prompt argument the prompt is read from standard input.",
                             "`--issue` starts from a GitHub issue: it names the branch and tells the agent to read the issue, so the prompt is optional and only adds to it.",
                             "`--with codex` or `--with claude` picks the coding agent, when the user asks for one by name. Without it, the agent is the one they chose for new tabs.",
                             "It returns once the agent has started. It doesn't wait for the work: see `bench wait`."],
                     examples: ["bench agent --branch fix/login \"Fix the crash on the login screen. Open a PR when done.\"",
                                "bench agent --branch turn-review < brief.md",
                                "bench agent --issue 412"],
                     valueOptions: ["branch", "base", "from", "issue", "project", "with"], isHeadline: true),
        BenchCommand("status", "[--all] [--json]",
                     summary: "What each session in this project and its agents is doing.",
                     when: "the user asks what the agents are doing, which ones need them, or how a pull request stands",
                     notes: ["Each agent is named by its branch. That name is what the other commands take.",
                             "`--all` covers every project in Workbench."],
                     examples: ["bench status", "bench status --json"],
                     valueOptions: ["project"], flags: ["all", "json"], isHeadline: true),
        BenchCommand("send", "<agent>[,<agent>...] | --all  <message>",
                     summary: "Send a message to another agent's session.",
                     when: "the user asks you to tell an agent something, to say go, or to pass on an answer",
                     notes: ["The other session sees who the message came from. It's never shown as typed by the user.",
                             "Give several agents with commas between them, or `--all` for every other agent in this project.",
                             "With no message argument the message is read from standard input.",
                             "A session that's waiting on a permission request or a question can't take a message. Only the user can answer those."],
                     examples: ["bench send turn-review \"Go ahead with your plan.\"", "bench send turn-review,watch-pr \"Go.\"", "bench send --all \"Go.\""],
                     valueOptions: ["project"], flags: ["all"], isHeadline: true),
        BenchCommand("read", "<agent> [--json]",
                     summary: "The last thing an agent said, in full.",
                     when: "the user asks what an agent replied, planned or found, or you need its answer to carry on",
                     examples: ["bench read turn-review"],
                     valueOptions: ["project"], flags: ["json"]),
        BenchCommand("wait", "<agent>... | --all  [--timeout <seconds>]",
                     summary: "Wait until agents stop working, then say where each one stands.",
                     when: "the user wants to know when agents finish, or your next step depends on their work",
                     notes: ["An agent has stopped when it's done, idle, or waiting for the user.",
                             "This can take a long time. Run it in the background if you have other work.",
                             "It fails if `--timeout` passes first."],
                     examples: ["bench wait --all", "bench wait turn-review watch-pr --timeout 1800"],
                     valueOptions: ["timeout", "project"], flags: ["all"]),
        BenchCommand("stop", "<agent>",
                     summary: "Interrupt what an agent is doing, as Escape would.",
                     when: "the user asks you to stop or interrupt an agent",
                     examples: ["bench stop watch-pr"],
                     valueOptions: ["project"]),
        BenchCommand("remove", "<agent>",
                     summary: "Remove a finished agent: its worktree, its branch if merged, and its row in Workbench.",
                     when: "the user asks you to clean up an agent whose work is merged or no longer wanted",
                     notes: ["It refuses when the worktree has uncommitted changes or commits that aren't pushed, and says which.",
                             "Throwing work away is the user's call, in Workbench itself.",
                             "Don't remove a worktree with git or rm: that leaves a dead row behind."],
                     examples: ["bench remove turn-review"],
                     valueOptions: ["project"]),
        BenchCommand("sessions", "[--json]",
                     summary: "This project's past conversations, newest first.",
                     when: "the user asks about earlier sessions, or wants one picked back up",
                     valueOptions: ["project"], flags: ["json"]),
        BenchCommand("resume", "<session id>",
                     summary: "Open a past conversation in a new agent tab, or go to the tab it's already in.",
                     when: "the user asks to pick a past session back up",
                     notes: ["Session ids come from `bench sessions`."],
                     valueOptions: ["project"]),

        // Showing things
        BenchCommand("open", "<file> | <url> | --diff [<file>] | --review [<commit>]",
                     summary: "Show something in a tab: a file, a web page, a file's changes, or a review of the branch or a commit.",
                     when: "the user asks to see a file, a diff, the changes on a branch, or a page such as a dev server",
                     notes: ["It brings that project to the front, so use it when asked to show something, not on your own.",
                             "A URL opens in Workbench's own preview tab, not the browser.",
                             "`--diff` with no file opens the review of everything changed on the branch."],
                     examples: ["bench open Sources/App/Login.swift", "bench open http://localhost:3000",
                                "bench open --diff Sources/App/Login.swift", "bench open --review"],
                     valueOptions: ["project"], flags: ["diff", "review"]),
        BenchCommand("run", "<command> | --shortcut <name>",
                     summary: "Run a command in a new shell tab the user can see and stop.",
                     when: "the user asks you to start a dev server, a watcher, or anything long-running they'll want to see",
                     notes: ["Prefer this to running a server in your own shell, where the user can't see or stop it.",
                             "`--shortcut` runs one of the user's saved shortcuts by name: see `bench shortcuts`.",
                             "`--show` switches to the new tab. Otherwise the tab the user is on stays in front."],
                     examples: ["bench run npm run dev", "bench run --shortcut Build"],
                     valueOptions: ["shortcut", "project"], flags: ["show"]),
        BenchCommand("shortcuts", "[--json]",
                     summary: "The user's saved shortcuts for this project, and which are running.",
                     when: "the user mentions one of their shortcuts, or asks what's running",
                     valueOptions: ["project"], flags: ["json"]),
        BenchCommand("ports", "[--json]",
                     summary: "The ports that servers started in this project's tabs are listening on.",
                     when: "you need the address of a dev server the user or an agent started",
                     valueOptions: ["project"], flags: ["json"]),
        BenchCommand("show", "<agent or project>",
                     summary: "Bring a project or agent to the front in Workbench.",
                     when: "the user asks to be taken to an agent or project",
                     examples: ["bench show turn-review"]),
        BenchCommand("notify", "[--mac | --phone] [--title <title>] <message>",
                     summary: "Show a notification on this Mac and on the user's iPhone when one is paired.",
                     when: "the user asks to be told when something is done, or to have a message sent to their phone",
                     notes: ["Keep it short, and send one only when asked to.",
                             "The title is the project's name unless `--title` says otherwise.",
                             "With no message argument the message is read from standard input."],
                     examples: ["bench notify \"Tests pass, PR is up\"", "bench notify --phone \"Deploy done\""],
                     valueOptions: ["title"], flags: ["mac", "phone", "iphone"], isHeadline: true),

        // Where things stand
        BenchCommand("usage", "[--json]",
                     summary: "How much of the Claude plan's limits is used, and when each resets.",
                     when: "the user asks how much usage is left, or before starting several agents at once",
                     valueOptions: ["project"], flags: ["json"]),
        BenchCommand("pr", "[<agent>] [--json]",
                     summary: "The pull request for a branch: its state, its checks, and any deploy that followed.",
                     when: "the user asks whether a PR is open, green, merged or deployed",
                     notes: ["With no agent, it's the pull request for the project this ran in."],
                     valueOptions: ["project"], flags: ["json"]),

        // The project list
        BenchCommand("projects", "[--json]",
                     summary: "Workbench's projects and their agents, with their folders.",
                     when: "the user asks which projects Workbench has",
                     flags: ["json"]),
        BenchCommand("add", "<folder>...",
                     summary: "Add folders as Workbench projects, each with an agent tab.",
                     when: "the user asks to add a folder or repo to Workbench",
                     notes: ["It only changes Workbench's list, never the folders."],
                     examples: ["bench add ~/Code/thing"]),
        BenchCommand("rename", "<new name>",
                     summary: "Rename this project in Workbench. The folder keeps its name.",
                     when: "the user asks to rename a project",
                     notes: ["An empty name goes back to the folder's name. Agents are named by their branch and can't be renamed."],
                     valueOptions: ["project"]),
        BenchCommand("pin", "", summary: "Pin this project to the top of the sidebar.",
                     when: "the user asks to pin a project", valueOptions: ["project"]),
        BenchCommand("unpin", "", summary: "Unpin this project.",
                     when: "the user asks to unpin a project", valueOptions: ["project"]),
        BenchCommand("base", "<branch> | --default",
                     summary: "Choose the branch this project's changes are compared against.",
                     when: "the user asks to compare against a different branch",
                     valueOptions: ["project"], flags: ["default"]),

        BenchCommand("help", "[<command>]",
                     summary: "This list, or everything about one command.",
                     when: "you're about to say what Workbench can or can't do"),
        BenchCommand("discard-feedback", "", summary: "Throw away this worktree, when it was made to look into feedback that needs nothing.",
                     when: "Workbench's feedback agent finds nothing to do", isHidden: true),
    ]

    /// What `bench` can't do, so Claude says so in place of improvising.
    public static let limits = [
        "answering another session's permission requests or questions",
        "changing a session's permission mode, model or account",
        "merging, or throwing away an agent's unsaved work",
        "changing Workbench's settings",
    ]

    // MARK: Help

    /// `bench help`: every command in a line or two, written for Claude.
    public static func help() -> String {
        var lines = ["bench: ask Workbench, the app this session runs in, to do things.", ""]
        let shown = all.filter { !$0.isHidden }
        let width = shown.map(\.name.count).max() ?? 0
        for command in shown {
            let name = command.name.padding(toLength: width, withPad: " ", startingAt: 0)
            lines.append("  \(name)  \(command.summary)")
            lines.append("  \(String(repeating: " ", count: width))  Use when \(command.when).")
        }
        lines.append("")
        lines.append("`bench help <command>` has the arguments, notes and examples for one command.")
        lines.append("Agents are named by their branch, as `bench status` lists them. Most commands act on the")
        lines.append("project they're run in; `--project <name or folder>` names another.")
        lines.append("")
        lines.append("Not possible with bench: " + limits.joined(separator: "; ") + ".")
        lines.append("Those are the user's to do in Workbench. If something else is missing here, say so plainly")
        lines.append("and don't substitute something that only looks similar.")
        return lines.joined(separator: "\n")
    }

    /// `bench help <command>`.
    public var help: String {
        var lines = [usage, "", summary, "Use when \(when)."]
        if !notes.isEmpty {
            lines.append("")
            lines += notes.map { "- \($0)" }
        }
        if !examples.isEmpty {
            lines.append("")
            lines.append(examples.count == 1 ? "Example:" : "Examples:")
            lines += examples.map { "  \($0)" }
        }
        return lines.joined(separator: "\n")
    }

    /// What a command that was called wrongly gets back.
    public var usageError: String { "usage: \(usage)\n`bench help \(name)` says more." }

    /// What an unknown command gets back: the closest names, then where
    /// to look.
    public static func unknown(_ name: String) -> String {
        let shown = all.filter { !$0.isHidden }.map(\.name)
        let close = shown.filter { $0.hasPrefix(name) || name.hasPrefix($0) || distance($0, name) <= 2 }
        var text = "bench has no command called '\(name)'."
        if !close.isEmpty { text += " Did you mean \(close.map { "`bench \($0)`" }.joined(separator: " or "))?" }
        return text + "\nCommands: " + shown.joined(separator: ", ") + ".\n`bench help` describes each one."
    }

    private static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var row = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var previous = row[0]
            row[0] = i
            for j in 1...max(b.count, 1) where !b.isEmpty {
                let old = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = old
            }
        }
        return row[b.count]
    }

    // MARK: What Claude is told

    /// What every Claude session Workbench starts is told about where it's
    /// running. It names only the commands that are costly to miss and
    /// points at `bench help` for the rest, so it rarely has to change and
    /// a long-running session's copy stays true.
    public static var note: String {
        let headline = all.filter(\.isHeadline).map { command in
            "`\(command.usage)`: \(command.summary) Use it when \(command.when)."
        }
        return """
            This session runs in a tab of Workbench, a Mac app that keeps a list of project folders and runs \
            terminals and Claude Code sessions inside each one. The `bench` command (on PATH, also at $BENCH_CLI) \
            asks Workbench to do things: start and steer agents, show files, diffs and pages in tabs, run commands \
            in tabs the user can see, report usage and pull requests, and manage the project list. Run `bench help` \
            for the full, current list before you tell the user that Workbench can or can't do something, and \
            whenever a request is about Workbench, its agents, tabs or projects. That list comes from the running \
            app, so trust it over this note. If bench can't do what was asked, say so and don't substitute \
            something that only looks similar. The commands that matter most:
            \(headline.joined(separator: "\n"))
            """
    }

    /// Changes whenever the commands do, so a session can tell that the
    /// app around it has learned something since it started.
    public static var version: String {
        var hash: UInt64 = 0xcbf29ce484222325
        for command in all where !command.isHidden {
            for byte in (command.name + "\u{1}" + command.arguments + "\u{1}" + command.summary).utf8 {
                hash = (hash ^ UInt64(byte)) &* 0x100000001b3
            }
        }
        return String(hash, radix: 16)
    }

    /// What a session is told, once, when the commands have changed
    /// since it started.
    public static let changedNotice = "Workbench has been updated since this session started, and the `bench` command has changed. " +
        "Run `bench help` for what it can do now before relying on what you were told earlier."
}
