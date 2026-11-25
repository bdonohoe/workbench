import AppKit
import BenchKit

/// What the `bench` tool prints, and how it exits.
struct BenchReply {
    enum Status: String {
        case ok, error
        /// Called wrongly. The tool exits the way a shell built-in would.
        case usage
        /// The tool should read standard input and ask again.
        case stdin
    }

    var status: Status
    var text: String

    static func ok(_ text: String) -> BenchReply { BenchReply(status: .ok, text: text) }
}

/// Carries out `bench` commands. The commands themselves are described in
/// `BenchCommand.all`; this is what each one does.
///
/// Nearly everything here goes through `CompanionSnapshots`, the same
/// calls the iPhone app makes, so a command and its button on the phone
/// can't drift apart.
final class BenchCommandRunner {
    private let store: AppStore
    private let terminals: TerminalManager
    private let snapshots: CompanionSnapshots
    /// `bench notify`, shown on the Mac and sent to paired phones.
    var notify: ((NotifyRequest) -> (ok: Bool, message: String))?
    /// `bench discard-feedback`, handled by the feedback agent.
    var discardFeedback: ((_ folder: String) -> (ok: Bool, message: String))?
    /// The paired iPhones' names, or nil when the companion is off.
    var phones: (() -> [String]?)?

    init(store: AppStore, terminals: TerminalManager, snapshots: CompanionSnapshots) {
        self.store = store
        self.terminals = terminals
        self.snapshots = snapshots
    }

    private struct Failure: Error {
        var status = BenchReply.Status.error
        var text: String
    }

    private static func fail(_ text: String) -> Failure { Failure(text: text) }

    /// `stillWanted` turns false when the tool that asked has gone away,
    /// so a long wait doesn't carry on for nobody.
    func run(_ request: BenchRequest, stillWanted: @escaping () -> Bool = { true }) async -> BenchReply {
        guard let name = request.commandName else { return .ok(BenchCommand.help()) }
        guard let command = BenchCommand.named(name) else {
            return BenchReply(status: .usage, text: BenchCommand.unknown(name))
        }
        do {
            let arguments = try BenchArguments(Array(request.arguments.dropFirst()), for: command,
                                               stopsAtFirstWord: command.name == "run")
            let call = Call(request: request, command: command, arguments: arguments, stillWanted: stillWanted)
            return .ok(try await perform(call))
        } catch let problem as BenchArguments.Problem {
            return BenchReply(status: .usage, text: problem.message + "\n" + command.usageError)
        } catch let failure as Failure {
            return BenchReply(status: failure.status, text: failure.text)
        } catch {
            return BenchReply(status: .error, text: error.localizedDescription)
        }
    }

    private struct Call {
        var request: BenchRequest
        var command: BenchCommand
        var arguments: BenchArguments
        var stillWanted: () -> Bool

        var wantsJSON: Bool { arguments.has("json") }

        func usage(_ why: String? = nil) -> Failure {
            Failure(status: .usage, text: (why.map { $0 + "\n" } ?? "") + command.usageError)
        }
    }

    private func perform(_ call: Call) async throws -> String {
        switch call.command.name {
        case "help": try help(call)
        case "agent": try await agent(call)
        case "status": try status(call)
        case "send": try send(call)
        case "read": try read(call)
        case "wait": try await wait(call)
        case "stop": try stop(call)
        case "remove": try await remove(call)
        case "sessions": try await sessions(call)
        case "resume": try await resume(call)
        case "open": try await open(call)
        case "run": try run(call)
        case "shortcuts": try shortcuts(call)
        case "ports": try ports(call)
        case "show": try show(call)
        case "notify": try notify(call)
        case "usage": try usage(call)
        case "pr": try pullRequest(call)
        case "projects": projects(call)
        case "add": try add(call)
        case "rename": try rename(call)
        case "pin": try pin(call, true)
        case "unpin": try pin(call, false)
        case "base": try await base(call)
        case "discard-feedback": try discard(call)
        default: throw Failure(status: .usage, text: BenchCommand.unknown(call.command.name))
        }
    }

    // MARK: Who and where

    private var targets: [BenchTarget] {
        store.projects.map {
            BenchTarget(id: $0.id, name: $0.name, branch: $0.isWorktree ? $0.branch : nil, path: $0.path,
                        parentID: $0.parentID, tabIDs: $0.tabs.map(\.id))
        }
    }

    /// The project a command is about: the one `--project` names, else
    /// the one it ran in.
    private func home(_ call: Call) throws -> BenchTarget {
        if let named = call.arguments.values["project"] {
            return try find(named, home: BenchTarget.home(tabID: call.request.tabID, folder: call.request.folder, among: targets))
        }
        guard let home = BenchTarget.home(tabID: call.request.tabID, folder: call.request.folder, among: targets) else {
            throw Self.fail("This folder isn't in a Workbench project. Say which one with --project. `bench projects` lists them.")
        }
        return home
    }

    private func find(_ name: String, home: BenchTarget?) throws -> BenchTarget {
        switch BenchTarget.find(name, home: home, among: targets) {
        case .one(let target):
            return target
        case .unknown(let name, let choices):
            let here = choices.isEmpty ? "Workbench has no projects yet." : "Here: \(choices.joined(separator: ", "))."
            throw Self.fail("Workbench has no agent or project called “\(name)”. \(here)")
        case .ambiguous(let name, let folders):
            throw Self.fail("More than one thing is called “\(name)”. Name its folder instead:\n" + folders.joined(separator: "\n"))
        }
    }

    private func project(_ target: BenchTarget) throws -> Project {
        guard let project = store.project(target.id) else { throw Self.fail("\(target.label) is no longer in Workbench.") }
        return project
    }

    /// The top-level project and its agents, the project first.
    private func family(of target: BenchTarget) -> [BenchTarget] {
        let rootID = target.parentID ?? target.id
        return targets.filter { $0.id == rootID } + targets.filter { $0.parentID == rootID }
    }

    /// The agents a command names: `--all` for every other one in the
    /// project, else each plain word, which may itself be a comma list.
    private func named(_ names: [String], all: Bool, call: Call) throws -> [BenchTarget] {
        let home = try home(call)
        if all {
            let others = family(of: home).filter { target in
                target.id != home.id && (try? claudeTab(in: project(target))) != nil
            }
            guard !others.isEmpty else { throw Self.fail("There are no other agents with a session in \(root(of: home).name).") }
            return others
        }
        let wanted = names.flatMap { $0.split(separator: ",").map(String.init) }.filter { !$0.isEmpty }
        guard !wanted.isEmpty else { throw call.usage("Name an agent, or use --all.") }
        return try wanted.map { try find($0, home: home) }
    }

    private func root(of target: BenchTarget) -> BenchTarget { BenchTarget.root(of: target, among: targets) }

    /// The Claude tab a project is known by: the one in front, else its first.
    private func claudeTab(in project: Project) throws -> TabRecord {
        if let selected = project.selectedTab, selected.kind == .agent { return selected }
        guard let tab = project.tabs.first(where: { $0.kind == .agent }) else {
            throw Self.fail("\(label(project)) has no agent tab.")
        }
        return tab
    }

    private func label(_ project: Project) -> String { project.isWorktree ? project.branch ?? project.name : project.name }

    /// The text a command was given: its plain words, else standard
    /// input, which the tool reads only once it's asked for.
    private func text(_ call: Call, from index: Int = 0, missing: String) throws -> String {
        if let text = call.arguments.text(from: index) { return text }
        guard let input = call.request.input else { throw Failure(status: .stdin, text: missing + "\n" + call.command.usageError) }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw call.usage(missing) }
        return text
    }

    private func json(_ value: Any) -> String {
        let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    private static func stamp(_ date: Date?) -> String? { date.map { ISO8601DateFormatter().string(from: $0) } }

    private static func ago(_ date: Date?) -> String? {
        date.map { PlanLimit.shortDuration(max(Date().timeIntervalSince($0), 0)) }
    }

    // MARK: Help

    private func help(_ call: Call) throws -> String {
        guard let name = call.arguments.positional.first else { return BenchCommand.help() }
        guard let command = BenchCommand.named(name.lowercased()), !command.isHidden else {
            throw Failure(status: .usage, text: BenchCommand.unknown(name))
        }
        return command.help
    }

    // MARK: Agents

    /// A new agent on its own branch and worktree, with a Claude tab
    /// started on the prompt. It belongs to the project the command named,
    /// or else the one it ran in; from an agent's own tab that's the
    /// agent's project, so agents can start siblings. The selection stays
    /// where it is.
    private func agent(_ call: Call) async throws -> String {
        let parent = try project(root(of: home(call)))
        // From a GitHub issue, the issue writes the prompt and names the
        // branch. Anything said besides goes under it.
        var issue: GitHubIssue?
        if let named = call.arguments.values["issue"] {
            guard let number = GitHubIssue.number(from: named) else {
                throw call.usage("“\(named)” isn't an issue number. Give one like --issue 412.")
            }
            guard PullRequests.ghPath != nil else {
                throw Self.fail("Starting from an issue needs the GitHub CLI. Install it with `brew install gh`, then `gh auth login`.")
            }
            guard let found = await GitHubIssues.issue(number, repo: parent.url) else {
                throw Self.fail("GitHub has no issue #\(number) for \(parent.name), or `gh` couldn't reach it. Try `gh issue view \(number)` there.")
            }
            issue = found
        }
        let prompt: String
        if let issue {
            let more = (call.arguments.text(from: 0) ?? call.request.input ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            prompt = more.isEmpty ? issue.prompt : issue.prompt + "\n\n" + more
        } else {
            prompt = try text(call, missing: "Say what the agent should work on.")
        }
        var agent: (any AgentProvider)?
        if let named = call.arguments.values["with"] {
            guard let found = Agents.offered(named: named) else {
                let names = Agents.offered.map { $0.id.rawValue }.joined(separator: " or ")
                throw call.usage("Workbench has no agent called “\(named)”. Give --with \(names).")
            }
            agent = found
        }
        let branch = call.arguments.values["branch"]?.nilIfEmpty ?? issue?.branch ?? Worktrees.suggestBranch(from: prompt)
        var base = (call.arguments.values["base"] ?? call.arguments.values["from"])?.nilIfEmpty
        if base == nil { base = await AgentLauncher.preferredBase(repo: parent.url) }
        let id = try await AgentLauncher.start(parent: parent, branch: branch, base: base, prompt: prompt,
                                               files: parent.setupFiles ?? Worktrees.suggestedSetupFiles(repo: parent.url),
                                               command: parent.setupCommand, select: false, savesSetup: false,
                                               store: store, terminals: terminals, agent: agent?.id)
        Analytics.capture(.agentStarted, ["kind": "single", "count": 1, "from_phone": false, "from_command": true, "from_issue": issue != nil,
                                          "agent": (agent ?? Agents.standard).id.rawValue])
        let folder = store.project(id)?.path ?? ""
        let who = agent.map { " with \($0.name)" } ?? ""
        return "Started an agent in \(parent.name) on \(branch)\(who).\n\(folder)\n"
            + "It's called “\(branch)” in other commands: `bench status`, `bench send \(branch) <message>`, `bench wait \(branch)`."
    }

    /// One project or agent as `status` reports it.
    private func report(_ target: BenchTarget, caller: UUID?) -> [String: Any] {
        guard let project = store.project(target.id) else { return [:] }
        let monitor = snapshots.monitors.monitor(for: project)
        var entry: [String: Any] = ["name": target.label, "kind": project.isWorktree ? "agent" : "project", "path": project.path]
        if let branch = monitor.snapshot?.branch ?? project.branch { entry["branch"] = branch }
        entry["sessions"] = project.tabs.filter { $0.kind == .agent }.map { tab -> [String: Any] in
            var session: [String: Any] = ["tab": tab.id.uuidString, "title": tab.displayTitle, "state": "not started"]
            if tab.id == caller { session["thisSession"] = true }
            guard let live = CompanionSnapshots.session(for: tab, terminals: terminals) else { return session }
            session["title"] = live.title
            session["state"] = Self.word(live.activity)
            if let since = live.since { session["since"] = Self.stamp(since) }
            if live.activity == .working || live.activity == .remoteWorking, let doing = live.action { session["doing"] = doing }
            if live.activity == .waiting, let question = live.question ?? live.questions?.first?.question { session["asking"] = question }
            // Read fresh: the sidebar's own copy can lag a turn behind.
            if let said = snapshots.transcriptPath(tabID: tab.id).flatMap(AgentStateWatcher.lastAssistantText) ?? live.summary {
                session["lastSaid"] = said
            }
            if let stopped = live.stoppedAt { session["stoppedAt"] = Self.stamp(stopped) }
            if let model = live.model { session["model"] = model }
            if let mode = live.permissionMode { session["permissionMode"] = mode }
            if let problem = live.replyProblem { session["cannotTakeMessages"] = problem }
            return session
        }
        if let pr = snapshots.pullRequests.info[project.id] { entry["pullRequest"] = Self.describe(pr) }
        if let deploy = snapshots.deployments.info[project.id] { entry["deploy"] = Self.describe(deploy) }
        let ports = snapshots.ports.ports(for: project).map(\.port).sorted()
        if !ports.isEmpty { entry["ports"] = ports }
        return entry
    }

    private static func word(_ activity: ActivityKind) -> String {
        switch activity {
        case .idle: "idle"
        case .working: "working"
        case .remoteWorking: "working on another Mac"
        case .waiting: "waiting for the user"
        case .done: "done"
        case .attention: "needs attention"
        }
    }

    private static func describe(_ pr: PullRequestInfo) -> [String: Any] {
        var entry: [String: Any] = ["number": pr.number, "title": pr.title, "url": pr.url.absoluteString]
        entry["state"] = switch pr.state {
        case .open: "open"
        case .draft: "draft"
        case .merged: "merged"
        case .closed: "closed"
        }
        entry["checks"] = switch pr.checks {
        case .none: "none"
        case .pending: "pending"
        case .passing: "passing"
        case .failing: "failing"
        }
        if pr.totalCount > 0 {
            entry["checksPassed"] = pr.passedCount
            entry["checksTotal"] = pr.totalCount
        }
        if !pr.failingNames.isEmpty { entry["failing"] = pr.failingNames }
        return entry
    }

    private static func describe(_ deploy: DeployInfo) -> [String: Any] {
        var entry: [String: Any] = ["pullRequest": deploy.prNumber, "places": deploy.environments]
        entry["state"] = switch deploy.state {
        case .deploying: "deploying"
        case .succeeded: "succeeded"
        case .failed: "failed"
        }
        if !deploy.failing.isEmpty { entry["failing"] = deploy.failing }
        if let url = deploy.url { entry["url"] = url.absoluteString }
        return entry
    }

    private static func line(pullRequest pr: [String: Any]) -> String {
        var text = "PR #\(pr["number"] ?? "") \(pr["state"] ?? ""): \(pr["title"] ?? "")"
        if let checks = pr["checks"] as? String, checks != "none" {
            text += "\n  Checks \(checks)"
            if let passed = pr["checksPassed"], let total = pr["checksTotal"] { text += " (\(passed) of \(total) passed)" }
            if let failing = pr["failing"] as? [String] { text += ". Failing: " + failing.joined(separator: ", ") }
        }
        if let url = pr["url"] { text += "\n  \(url)" }
        return text
    }

    private static func line(deploy: [String: Any]) -> String {
        var text = "Deploy of PR #\(deploy["pullRequest"] ?? "") \(deploy["state"] ?? "")"
        if let places = deploy["places"] as? [String], !places.isEmpty { text += " to " + places.joined(separator: ", ") }
        if let failing = deploy["failing"] as? [String] { text += ". Failing: " + failing.joined(separator: ", ") }
        if let url = deploy["url"] { text += "\n  \(url)" }
        return text
    }

    /// A report as a few lines of text, the name first.
    private static func lines(_ entry: [String: Any], full: Bool = true) -> [String] {
        var head = "\(entry["name"] ?? "")  (\(entry["kind"] ?? "")"
        if let branch = entry["branch"] as? String, branch != entry["name"] as? String { head += ", on \(branch)" }
        head += ")"
        var lines = [head]
        let sessions = entry["sessions"] as? [[String: Any]] ?? []
        if sessions.isEmpty { lines.append("  No agent tab.") }
        for session in sessions {
            var text = "  Session: \(session["state"] ?? "")"
            if sessions.count > 1, let title = session["title"] { text = "  Session “\(title)”: \(session["state"] ?? "")" }
            if session["thisSession"] != nil { text += " (this session)" }
            if let doing = session["doing"] { text += ". \(doing)" }
            lines.append(text)
            if let asking = session["asking"] { lines.append("    Asking: \(asking)") }
            if let said = session["lastSaid"], session["thisSession"] == nil, session["state"] as? String != "working" {
                lines.append("    Last said: \(said)")
            }
        }
        guard full else { return lines }
        if let pr = entry["pullRequest"] as? [String: Any] {
            lines += line(pullRequest: pr).split(separator: "\n").map { "  " + $0.trimmingCharacters(in: .whitespaces) }
        }
        if let deploy = entry["deploy"] as? [String: Any] {
            lines += line(deploy: deploy).split(separator: "\n").map { "  " + $0.trimmingCharacters(in: .whitespaces) }
        }
        if let ports = entry["ports"] as? [Int] { lines.append("  Ports: " + ports.map(String.init).joined(separator: ", ")) }
        return lines
    }

    private func status(_ call: Call) throws -> String {
        let caller = call.request.tabID
        let shown: [BenchTarget]
        var top: [String: Any] = [:]
        if call.arguments.has("all") {
            shown = store.topLevelProjects.flatMap { project in targets.filter { $0.id == project.id || $0.parentID == project.id } }
        } else {
            let home = try home(call)
            let root = root(of: home)
            shown = family(of: home)
            top["project"] = root.name
            top["claudeAccount"] = ClaudeAccounts.shared.profile(store.claudeAccountID(for: root.id)).name
        }
        if let phones = phones?() { top["pairedPhones"] = phones }
        let entries = shown.map { report($0, caller: caller) }
        if call.wantsJSON {
            top["agents"] = entries
            return json(top)
        }
        var lines: [String] = []
        for entry in entries { lines += Self.lines(entry) }
        if let account = top["claudeAccount"] { lines.append("\nClaude account: \(account)") }
        switch phones?() {
        case nil: lines.append("iPhone: the companion is off, so notifications stay on this Mac.")
        case let names? where names.isEmpty: lines.append("iPhone: none paired, so notifications stay on this Mac.")
        case let names?: lines.append("iPhone: \(names.formatted(.list(type: .and))) paired.")
        }
        return lines.joined(separator: "\n")
    }

    /// Who a message is from, so the session that gets it never takes
    /// another session's words for the user's.
    private func sender(_ call: Call) -> String {
        guard let home = BenchTarget.home(tabID: call.request.tabID, folder: call.request.folder, among: targets),
              let project = store.project(home.id) else { return "the command line" }
        let place = project.isWorktree ? "the agent “\(label(project))” in \(root(of: home).name)" : "the project \(project.name)"
        let isAgent = project.tabs.first { $0.id == call.request.tabID }?.kind == .agent
        return (isAgent ? "the Claude session in " : "a shell tab in ") + place
    }

    private func send(_ call: Call) throws -> String {
        let all = call.arguments.has("all")
        let message = try text(call, from: all ? 0 : 1, missing: "Say what to send.")
        let to = try named(Array(call.arguments.positional.prefix(1)), all: all, call: call)
        let wrapped = "[From \(sender(call)), sent with `bench send`. The user did not type this.]\n\n\(message)"
        var lines: [String] = []
        var failed = false
        for target in to {
            let tab = try claudeTab(in: project(target))
            if tab.id == call.request.tabID {
                lines.append("\(target.label): that's this session.")
                failed = true
            } else if let problem = snapshots.reply(wrapped, tabID: tab.id) {
                lines.append("\(target.label): not sent. \(problem)")
                failed = true
            } else {
                lines.append("\(target.label): sent.")
            }
        }
        if failed { throw Self.fail(lines.joined(separator: "\n")) }
        return lines.joined(separator: "\n")
    }

    private func read(_ call: Call) throws -> String {
        guard let name = call.arguments.positional.first else { throw call.usage("Name the agent to read.") }
        let target = try find(name, home: try? home(call))
        let project = try project(target)
        let tab = try claudeTab(in: project)
        let said = snapshots.transcriptPath(tabID: tab.id).flatMap(AgentStateWatcher.lastAssistantMessage)
        let entry = report(target, caller: call.request.tabID)
        if call.wantsJSON {
            var result = entry
            result["lastMessage"] = said ?? NSNull()
            return json(result)
        }
        let head = Self.lines(entry, full: false).filter { !$0.contains("Last said:") }.joined(separator: "\n")
        return head + "\n\n" + (said ?? "It hasn't said anything yet.")
    }

    private func isBusy(_ target: BenchTarget) -> Bool {
        guard let project = store.project(target.id) else { return false }
        return project.tabs.contains { tab in
            tab.kind == .agent && [.working, .remoteWorking].contains(CompanionSnapshots.session(for: tab, terminals: terminals)?.activity)
        }
    }

    private func wait(_ call: Call) async throws -> String {
        let all = call.arguments.has("all")
        let watched = try named(call.arguments.positional, all: all, call: call)
        var limit: TimeInterval?
        if let given = call.arguments.values["timeout"] {
            guard let seconds = TimeInterval(given), seconds > 0 else { throw call.usage("--timeout takes a number of seconds.") }
            limit = seconds
        }
        let started = Date()
        // A session that was just sent something takes a moment to show
        // as working, so it has to look stopped for a few seconds running.
        var quiet = 0
        while quiet < 3 {
            guard call.stillWanted() else { throw Self.fail("Stopped waiting.") }
            if let limit, Date().timeIntervalSince(started) > limit {
                let busy = watched.filter(isBusy).map(\.label)
                throw Self.fail("Still working after \(Int(limit)) seconds: \(busy.joined(separator: ", ")).")
            }
            quiet = watched.contains(where: isBusy) ? 0 : quiet + 1
            try? await Task.sleep(for: .seconds(1))
        }
        return watched.flatMap { Self.lines(report($0, caller: call.request.tabID)) }.joined(separator: "\n")
    }

    private func stop(_ call: Call) throws -> String {
        guard let name = call.arguments.positional.first else { throw call.usage("Name the agent to stop.") }
        let target = try find(name, home: try? home(call))
        let tab = try claudeTab(in: project(target))
        guard tab.id != call.request.tabID else { throw Self.fail("That's this session.") }
        if let problem = snapshots.interrupt(tabID: tab.id) { throw Self.fail("\(target.label): \(problem)") }
        return "Stopped \(target.label)."
    }

    private func remove(_ call: Call) async throws -> String {
        guard let name = call.arguments.positional.first else { throw call.usage("Name the agent to remove.") }
        let home = try? home(call)
        let target = try find(name, home: home)
        let project = try project(target)
        guard project.isWorktree else {
            throw Self.fail("\(project.name) is a project, not an agent. Only an agent's worktree can be removed this way.")
        }
        guard project.id != home?.id else { throw Self.fail("This session is running in that worktree. Remove it from another one.") }
        guard !isBusy(target) else { throw Self.fail("\(target.label) is still working. Stop it first with `bench stop \(target.label)`.") }
        var left = await Worktrees.leftovers(project.url, branch: project.branch)
        // A branch that was never pushed has nothing to compare with, but
        // it's still safe to remove when every commit on it is also on
        // another branch: merged locally, or never worked on at all.
        if left == .unpushed || left == .unknown, let branch = project.branch, await !Worktrees.hasUncommittedChanges(project.url),
           let only = await GitClient(root: project.url).optionalString(
               ["rev-list", "--count", "HEAD", "--not", "--exclude=refs/heads/\(branch)", "--branches", "--remotes"]),
           Int(only) == 0 {
            left = .none
        }
        switch left {
        case .none:
            break
        case .uncommitted:
            throw Self.fail("\(target.label) has uncommitted changes, so it wasn't removed. Commit them, or the user can discard the agent in Workbench.")
        case .unpushed:
            throw Self.fail("\(target.label) has commits that aren't pushed or merged, so it wasn't removed. Push them, or the user can discard the agent in Workbench.")
        case .unknown:
            throw Self.fail("Couldn't check \(target.label) for unsaved work, so it wasn't removed. The user can remove it in Workbench.")
        }
        guard try await snapshots.removeAgent(projectID: project.id) else { throw Self.fail("\(target.label) is no longer in Workbench.") }
        Analytics.capture(.agentRemoved, ["kind": "clean_up", "from_phone": false, "from_command": true])
        return "Removed \(target.label)."
    }

    private func sessions(_ call: Call) async throws -> String {
        let project = try project(home(call))
        let past = await snapshots.pastSessions(projectID: project.id)
        if call.wantsJSON {
            return json(past.map { session -> [String: Any] in
                var entry: [String: Any] = ["id": session.id, "modified": Self.stamp(session.modified) ?? ""]
                if let title = session.title { entry["title"] = title }
                if let first = session.firstPrompt { entry["firstPrompt"] = first }
                if let last = session.lastPrompt { entry["lastPrompt"] = last }
                if let branch = session.branch { entry["branch"] = branch }
                if let tab = session.openTabID { entry["openInTab"] = tab.uuidString }
                return entry
            })
        }
        guard !past.isEmpty else { return "\(label(project)) has no past sessions." }
        var lines = past.prefix(20).map { session in
            let title = session.title ?? session.firstPrompt ?? "Untitled"
            let short = title.count > 70 ? String(title.prefix(69)) + "…" : title
            return "\(session.id)  \(Self.ago(session.modified) ?? "") ago\(session.openTabID == nil ? "" : ", open now")  \(short)"
        }
        if past.count > 20 { lines.append("And \(past.count - 20) older. `bench sessions --json` has them all.") }
        return lines.joined(separator: "\n")
    }

    private func resume(_ call: Call) async throws -> String {
        guard let wanted = call.arguments.positional.first else { throw call.usage("Give a session id from `bench sessions`.") }
        let project = try project(home(call))
        let matches = await snapshots.pastSessions(projectID: project.id).filter { $0.id.hasPrefix(wanted) }
        guard let session = matches.first else {
            throw Self.fail("\(label(project)) has no past session whose id starts with “\(wanted)”. `bench sessions` lists them.")
        }
        guard matches.count == 1 else { throw Self.fail("Several sessions start with “\(wanted)”. Give more of the id.") }
        guard snapshots.resume(projectID: project.id, sessionID: session.id) != nil else {
            throw Self.fail("Couldn't open that session.")
        }
        return session.openTabID == nil ? "Opened that session in a new agent tab in \(label(project))."
            : "That session is already open. Its tab is in front now."
    }

    // MARK: Showing things

    private func open(_ call: Call) async throws -> String {
        let project = try project(home(call))
        let said = try await open(call, in: project)
        // Asked to be shown something, so that project comes to the front.
        store.selectedProjectID = project.id
        return said
    }

    private func open(_ call: Call, in project: Project) async throws -> String {
        let what = call.arguments.positional.first
        let monitor = snapshots.monitors.monitor(for: project)

        if call.arguments.has("review") || (call.arguments.has("diff") && what == nil) {
            guard let what else {
                store.openReview(.branch(monitor.snapshot?.branch ?? project.branch), in: project.id)
                return "Opened the review of everything changed on this branch in \(label(project))."
            }
            guard let commit = await monitor.client.commit(what) else { throw Self.fail("There's no commit “\(what)” in \(label(project)).") }
            store.openReview(.commit(commit), in: project.id)
            return "Opened the review of \(commit.subject)."
        }

        guard let what else { throw call.usage("Say what to open.") }

        if call.arguments.has("diff") {
            let path = relative(what, to: project, from: call.request.folder)
            guard let changes = snapshots.changes(projectID: project.id) else {
                monitor.refresh()
                throw Self.fail("Workbench is still reading this repo. Try again in a moment.")
            }
            let every = changes.unstaged + changes.staged + changes.againstBase
            guard let change = every.first(where: { $0.path == path }) else {
                let names = Array(Set(every.map(\.path))).sorted().prefix(30)
                throw Self.fail("\(path) has no changes." + (names.isEmpty ? " Nothing has changed here." : " Changed files:\n" + names.joined(separator: "\n")))
            }
            store.openDiff(change, in: project.id, keep: true)
            return "Opened the changes to \(path)."
        }

        if let url = Self.webAddress(what) {
            store.openPreview(url, in: project.id)
            return "Opened \(url.absoluteString) in a browser tab in \(label(project))."
        }

        let path = relative(what, to: project, from: call.request.folder)
        let full = path.hasPrefix("/") ? path : project.url.appendingPathComponent(path).path
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: full, isDirectory: &isFolder) else { throw Self.fail("There's no file at \(full).") }
        guard !isFolder.boolValue else { throw Self.fail("\(full) is a folder. Name a file.") }
        store.openFile(path, in: project.id)
        return "Opened \(path) in \(label(project))."
    }

    /// A path as the project's tabs name files: from the project's folder
    /// when it's inside, in full otherwise.
    private func relative(_ path: String, to project: Project, from folder: String?) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let base = URL(fileURLWithPath: folder ?? project.path)
        let full = (expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : base.appendingPathComponent(expanded)).standardizedFileURL.path
        let root = project.url.standardizedFileURL.path
        return full.hasPrefix(root + "/") ? String(full.dropFirst(root.count + 1)) : full
    }

    /// "http://localhost:3000" from that, from "localhost:3000", or from ":3000".
    private static func webAddress(_ text: String) -> URL? {
        if text.hasPrefix("http://") || text.hasPrefix("https://") { return URL(string: text) }
        if text.hasPrefix(":"), Int(text.dropFirst()) != nil { return URL(string: "http://localhost\(text)") }
        if text.hasPrefix("localhost") || text.hasPrefix("127.0.0.1") { return URL(string: "http://\(text)") }
        return nil
    }

    private func run(_ call: Call) throws -> String {
        let project = try project(home(call))
        let front = project.selectedTabID
        defer {
            // The tab the user is on stays in front unless they asked to see the new one.
            if !call.arguments.has("show"), let front, store.project(project.id)?.tabs.contains(where: { $0.id == front }) == true {
                store.selectTab(front, in: project.id)
            }
        }
        if let name = call.arguments.values["shortcut"] {
            let all = snapshots.companionShortcuts(for: project)
            guard let shortcut = all.first(where: { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }) else {
                let names = all.map(\.name)
                throw Self.fail("There's no shortcut called “\(name)” for \(label(project))."
                                + (names.isEmpty ? " It has none." : " Its shortcuts: \(names.joined(separator: ", "))."))
            }
            guard snapshots.runShortcut(projectID: project.id, shortcutID: shortcut.id) else {
                throw Self.fail("“\(shortcut.name)” is already running in \(label(project)).")
            }
            return "Running “\(shortcut.name)” (\(shortcut.command)) in a new tab in \(label(project))."
        }
        guard let command = call.arguments.text() else { throw call.usage("Say what to run.") }
        guard let tab = store.addTab(.shell, to: project.id, command: command), let updated = store.project(project.id) else {
            throw Self.fail("Couldn't open a tab in \(label(project)).")
        }
        _ = terminals.session(for: tab, in: updated)
        return "Running `\(command)` in a new tab in \(label(project)). `bench ports` shows what it listens on once it's up."
    }

    private func shortcuts(_ call: Call) throws -> String {
        let project = try project(home(call))
        let all = snapshots.companionShortcuts(for: project)
        if call.wantsJSON {
            return json(all.map { ["name": $0.name, "command": $0.command, "running": $0.isRunning, "ports": $0.ports] as [String: Any] })
        }
        guard !all.isEmpty else { return "\(label(project)) has no shortcuts." }
        return all.map { shortcut in
            var line = "\(shortcut.name): \(shortcut.command)"
            if shortcut.isRunning {
                line += shortcut.ports.isEmpty ? "  (running)" : "  (running on \(shortcut.ports.map(String.init).joined(separator: ", ")))"
            }
            return line
        }.joined(separator: "\n")
    }

    private func ports(_ call: Call) throws -> String {
        let project = try project(home(call))
        // Asked for now, since the scanner only looks while someone is watching.
        snapshots.ports.scan()
        let found = project.tabs.flatMap { tab in
            snapshots.ports.ports(forTab: tab.id).map { (port: $0.port, tab: tab.displayTitle) }
        }.sorted { $0.port < $1.port }
        if call.wantsJSON {
            return json(found.map { ["port": $0.port, "url": "http://localhost:\($0.port)", "tab": $0.tab] as [String: Any] })
        }
        guard !found.isEmpty else {
            return "Nothing started in \(label(project))'s tabs is listening on a port. A server that just started can take a few seconds to show up."
        }
        return found.map { "http://localhost:\($0.port)  from the tab “\($0.tab)”" }.joined(separator: "\n")
    }

    private func show(_ call: Call) throws -> String {
        let home = try? home(call)
        let target = try call.arguments.positional.first.map { try find($0, home: home) } ?? self.home(call)
        let project = try project(target)
        store.selectedProjectID = project.id
        NSApp.activate()
        return "\(label(project)) is in front in Workbench."
    }

    private func notify(_ call: Call) throws -> String {
        let message = try text(call, missing: "Say what the notification should say.")
        guard let trimmed = NotifyRequest.trimmed(message) else { throw call.usage("Say what the notification should say.") }
        guard let notify else { throw Self.fail("Workbench isn't ready to show notifications yet.") }
        let target: NotifyRequest.Target = call.arguments.has("mac") ? .mac
            : call.arguments.has("phone") || call.arguments.has("iphone") ? .phone : .both
        let title = call.arguments.values["title"]?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        let result = notify(NotifyRequest(tabID: call.request.tabID, target: target, title: title, message: trimmed))
        guard result.ok else { throw Self.fail(result.message) }
        return result.message
    }

    // MARK: Where things stand

    private func usage(_ call: Call) throws -> String {
        let home = try? home(call)
        let accountID = home.map { store.claudeAccountID(for: $0.id) } ?? ClaudeProfile.mainID
        let account = ClaudeAccounts.shared.profile(accountID).name
        let usage = ClaudeAccounts.shared.monitor(for: accountID).usage
        let now = Date()
        let limits = (usage?.limits ?? []).map { limit -> [String: Any] in
            var entry: [String: Any] = ["name": limit.name, "percentUsed": (limit.resetsAt.map { $0 <= now } == true ? 0 : limit.percent).rounded()]
            if let reset = limit.resetsAt, reset > now {
                entry["resetsAt"] = Self.stamp(reset)
                entry["resetsIn"] = limit.timeLeft(at: now)
            }
            if let dollars = limit.dollars { entry["dollars"] = dollars }
            return entry
        }
        if call.wantsJSON {
            return json(["claudeAccount": account, "limits": limits, "updated": Self.stamp(usage?.updated) ?? NSNull()] as [String: Any])
        }
        guard !limits.isEmpty else {
            return "Workbench has no plan limits for the Claude account “\(account)” yet. An account that pays per token has none."
        }
        var lines = ["Claude account: \(account)"]
        for limit in limits {
            var line = "\(limit["name"] ?? ""): \(Int(limit["percentUsed"] as? Double ?? 0))% used"
            if let dollars = limit["dollars"] as? Double { line += " (\(PlanLimit.shortDollars(dollars)) spent)" }
            if let left = limit["resetsIn"] { line += ", resets in \(left)" }
            lines.append(line)
        }
        if let updated = usage?.updated { lines.append("As of \(Self.ago(updated) ?? "") ago.") }
        return lines.joined(separator: "\n")
    }

    private func pullRequest(_ call: Call) throws -> String {
        let home = try? home(call)
        let target = try call.arguments.positional.first.map { try find($0, home: home) } ?? self.home(call)
        let project = try project(target)
        let pr = snapshots.pullRequests.info[project.id].map(Self.describe)
        let deploy = snapshots.deployments.info[project.id].map(Self.describe)
        if call.wantsJSON {
            return json(["name": target.label, "pullRequest": pr ?? NSNull(), "deploy": deploy ?? NSNull()] as [String: Any])
        }
        guard let pr else {
            return "Workbench knows of no pull request for \(target.label). One that was just opened can take a minute to show up."
        }
        return ([Self.line(pullRequest: pr)] + (deploy.map { [Self.line(deploy: $0)] } ?? [])).joined(separator: "\n")
    }

    // MARK: The project list

    private func projects(_ call: Call) -> String {
        if call.wantsJSON {
            return json(store.topLevelProjects.map { project -> [String: Any] in
                ["name": project.name, "path": project.path, "pinned": store.isPinned(project.id),
                 "agents": store.worktrees(of: project.id).map { ["name": label($0), "path": $0.path] }]
            })
        }
        var lines: [String] = []
        for project in store.topLevelProjects {
            lines.append("\(project.name)\t\(project.path)")
            for worktree in store.worktrees(of: project.id) {
                lines.append("  \(worktree.branch ?? worktree.name)\t\(worktree.path)")
            }
        }
        return lines.isEmpty ? "Workbench has no projects yet." : lines.joined(separator: "\n")
    }

    private func add(_ call: Call) throws -> String {
        guard !call.arguments.positional.isEmpty else { throw call.usage("Name the folders to add.") }
        var lines: [String] = []
        var ok = true
        for given in call.arguments.positional {
            let expanded = (given as NSString).expandingTildeInPath
            let folder = expanded.hasPrefix("/") ? expanded
                : URL(fileURLWithPath: call.request.folder ?? "/").appendingPathComponent(expanded).standardizedFileURL.path
            switch store.addProject(path: folder, source: .benchCommand) {
            case .added(let project):
                lines.append("Added \(project.name) to Workbench.")
            case .alreadyHere(let project):
                lines.append("\(project.name) is already in Workbench.")
            case .notAFolder:
                lines.append("No folder at \(folder).")
                ok = false
            }
        }
        if !ok { throw Self.fail(lines.joined(separator: "\n")) }
        return lines.joined(separator: "\n")
    }

    private func rename(_ call: Call) throws -> String {
        let project = try project(root(of: home(call)))
        let name = call.arguments.text() ?? ""
        store.renameProject(project.id, to: name)
        let now = store.project(project.id)?.name ?? name
        return name.isEmpty ? "\(project.name) goes by its folder's name again: \(now)." : "\(project.name) is now called \(now)."
    }

    private func pin(_ call: Call, _ pinned: Bool) throws -> String {
        let project = try project(root(of: home(call)))
        store.setPinned(project.id, pinned)
        return pinned ? "Pinned \(project.name)." : "Unpinned \(project.name)."
    }

    private func base(_ call: Call) async throws -> String {
        let project = try project(home(call))
        if call.arguments.has("default") {
            snapshots.setBaseRef(nil, projectID: project.id)
            return "\(label(project)) compares against its usual branch again."
        }
        guard let branch = call.arguments.positional.first else { throw call.usage("Name a branch, or use --default.") }
        guard branch.rangeOfCharacter(from: .whitespacesAndNewlines) == nil, !branch.hasPrefix("-") else {
            throw Self.fail("“\(branch)” isn't a branch name.")
        }
        guard await GitClient(root: project.url).optionalString(["rev-parse", "--verify", "-q", "\(branch)^{commit}"]) != nil else {
            let known = snapshots.monitors.monitor(for: project).branches.prefix(20)
            throw Self.fail("\(label(project)) has no branch “\(branch)”." + (known.isEmpty ? "" : " Its branches: \(known.joined(separator: ", "))."))
        }
        snapshots.setBaseRef(branch, projectID: project.id)
        return "\(label(project))'s changes are now compared against \(branch)."
    }

    private func discard(_ call: Call) throws -> String {
        guard let folder = call.request.folder, let discardFeedback else {
            throw Self.fail("Workbench's feedback agent isn't set up on this Mac.")
        }
        let result = discardFeedback(folder)
        guard result.ok else { throw Self.fail(result.message) }
        return result.message
    }
}
