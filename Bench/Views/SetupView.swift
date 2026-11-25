import AppKit
import BenchKit
import SwiftUI

/// Checks for the tools Bench depends on.
@MainActor @Observable
final class SetupCheck {
    enum Status: Equatable {
        case checking
        case ok(String)
        case missing(String)
        /// Not installed, but Bench works without it.
        case skipped(String)
    }

    struct Item: Identifiable {
        let id: String
        let name: String
        let purpose: String
        /// Marked "Beta" beside its name.
        var isBeta = false
        var status: Status = .checking
        var fix: Fix?
    }

    enum Fix {
        case link(String, URL)
        case installCommandLineTools
        /// The agent isn't on this Mac.
        case installAgent(AgentSetup)
        /// The agent is installed but has no account to use.
        case signInToAgent(AgentSetup)
        case note(String)
    }

    static let seenKey = "hasSeenSetup"
    static let shared = SetupCheck()

    /// The coding agents, then the other tools.
    private(set) var items: [Item] = AgentSetup.all.map { Item(id: $0.id.rawValue, name: $0.product, purpose: $0.maker, isBeta: $0.isBeta) } + [
        Item(id: "git", name: "git", purpose: "Shows changes, branches, and agents."),
        Item(id: "gh", name: "GitHub CLI", purpose: "Optional. Shows pull requests and their checks."),
        Item(id: "tailscale", name: "Tailscale", purpose: "Optional. Connects your iPhone and other Macs."),
    ]
    /// What's known about each agent on this Mac.
    private(set) var agents = AgentSetup.all
    private(set) var isChecking = false

    /// The agents' rows, and everything else's.
    var agentItems: [Item] { items.filter { item in agents.contains { $0.id.rawValue == item.id } } }
    var toolItems: [Item] { items.filter { item in !agents.contains { $0.id.rawValue == item.id } } }
    var readyAgents: [AgentSetup] { agents.filter(\.state.isReady) }
    /// False until the first check has come back.
    var hasChecked: Bool { !agents.contains { $0.state == .checking } }

    /// True when something Bench needs is missing.
    var needsAttention: Bool {
        items.contains { if case .missing = $0.status { true } else { false } }
    }

    func run(rescan: Bool = false) async {
        guard !isChecking else { return }
        isChecking = true
        let found = await Task.detached { Self.check(rescan: rescan) }.value
        agents = found.agents
        for agent in found.agents {
            guard let index = items.firstIndex(where: { $0.id == agent.id.rawValue }) else { continue }
            // Workbench needs one agent. While none is ready, the one it
            // asks for is the one it's built for, not one in beta.
            let anotherIsReady = found.agents.contains { $0.id != agent.id && $0.state.isReady }
            let anotherIsPreferred = agent.isBeta && found.agents.contains { !$0.isBeta }
            (items[index].status, items[index].fix) = Self.row(for: agent, isOptional: anotherIsReady || anotherIsPreferred)
        }
        for (id, result) in found.tools {
            guard let index = items.firstIndex(where: { $0.id == id }) else { continue }
            items[index].status = result.0
            items[index].fix = result.1
        }
        isChecking = false
        settleDefaultAgent()
    }

    /// New tabs run an agent that's ready: your choice while it is, or
    /// else the one that is. Nothing is saved until there's a reason to.
    private func settleDefaultAgent() {
        let chosen = Agents.standardID()
        let preferred = AgentSetup.preferred(among: agents, chosen: chosen)
        if preferred != chosen { UserDefaults.standard.set(preferred.rawValue, forKey: Agents.defaultAgentKey) }
    }

    /// An agent's row. A missing agent is only a problem when it's the
    /// one Workbench is waiting on.
    nonisolated static func row(for agent: AgentSetup, isOptional: Bool) -> (Status, Fix?) {
        switch agent.state {
        case .checking: (.checking, nil)
        case .ready(let version): (.ok(version.map { "Version \($0)" } ?? "Ready"), nil)
        case .signedOut:
            (isOptional ? .skipped("Installed, but not signed in.") : .missing("Installed, but not signed in."), .signInToAgent(agent))
        case .notInstalled:
            (isOptional ? .skipped("Not installed. Add it any time.") : .missing("Not installed."), .installAgent(agent))
        }
    }

    nonisolated private static func check(rescan: Bool) -> (agents: [AgentSetup], tools: [(String, (Status, Fix?))]) {
        if rescan { Tools.recheck() } else { Tools.resolveIfNeeded() }
        AgentPrograms.forget()
        var agents = AgentSetup.all
        for index in agents.indices { agents[index].state = AgentSetup.state(of: agents[index].id) }
        var results: [(String, (Status, Fix?))] = []

        if let git = Tools.git {
            results.append(("git", (.ok(git), nil)))
        } else {
            results.append(("git", (.missing("Apple's command line tools aren't installed."), .installCommandLineTools)))
        }

        if let gh = Tools.path("gh") {
            if Tools.run(gh, ["auth", "status"], environment: Tools.environment) != nil {
                results.append(("gh", (.ok("Signed in"), nil)))
            } else {
                results.append(("gh", (.skipped("Installed, but not signed in."), .note("Run gh auth login in a terminal tab."))))
            }
        } else {
            results.append(("gh", (.skipped("Not installed."), .link("Get the GitHub CLI", URL(string: "https://cli.github.com")!))))
        }

        if let tailscale = Tailscale.binary {
            let signedIn = Tools.run(tailscale, ["status", "--json"], environment: Tailscale.environment)
                .flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                .flatMap { $0["BackendState"] as? String } == "Running"
            results.append(("tailscale", signedIn ? (.ok("Running"), nil)
                           : (.skipped("Installed, but not running or signed in."), .note("Open Tailscale and sign in."))))
        } else {
            results.append(("tailscale", (.skipped("Not installed."), .link("Get Tailscale", URL(string: "https://tailscale.com/download/mac")!))))
        }
        return (agents, results)
    }

    /// Whether Claude Code has an account or API key to use, from
    /// `claude auth status`. Nil when it can't tell (an older Claude Code
    /// without that command), which counts as signed in.
    nonisolated static func claudeSignedIn(_ claude: String) -> Bool? {
        #if DEBUG
        // BENCH_CLAUDE_SIGNED_OUT=1 shows the signed-out state, for testing.
        if ProcessInfo.processInfo.environment["BENCH_CLAUDE_SIGNED_OUT"] == "1" { return false }
        #endif
        return ClaudeAccount.read(claude: claude)?.loggedIn
    }
}

struct SetupRow: View {
    let item: SetupCheck.Item
    /// Its place in the list. Each row's mark lands a beat after the one
    /// above, so the answers run down the list rather than all flipping
    /// at once.
    var order = 0
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            // A stack of its own, so the marks have somewhere steady to
            // swap in: a transition needs a parent that stays put.
            ZStack { icon }
                .animation(Theme.Motion.state.delay(Double(order) * 0.06), value: item.status)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.isBeta ? "\(item.name) (Beta)" : item.name).fontWeight(.medium)
                Text(item.purpose).font(.callout).foregroundStyle(.secondary)
                if let detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            fix
        }
        .padding(.vertical, 2)
    }

    private var detail: String? {
        switch item.status {
        case .checking: nil
        case .ok(let text), .missing(let text), .skipped(let text): text
        }
    }

    @ViewBuilder private var icon: some View {
        switch item.status {
        case .checking:
            ProgressView().controlSize(.small).transition(.blurReplace)
        case .ok:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.Status.done).transition(.blurReplace)
        case .missing:
            Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.Status.failed).transition(.blurReplace)
        case .skipped:
            Image(systemName: "minus.circle").foregroundStyle(.secondary).transition(.blurReplace)
        }
    }

    @ViewBuilder private var fix: some View {
        switch item.fix {
        case .link(let title, let url):
            Link(title, destination: url)
        case .installCommandLineTools:
            Button("Install") {
                Task.detached { _ = Tools.run("/usr/bin/xcode-select", ["--install"]) }
            }
        case .installAgent(let agent):
            AgentSetupButton(agent: agent, action: .install)
        case .signInToAgent(let agent):
            AgentSetupButton(agent: agent, action: .signIn)
        case .note(let text):
            Text(text).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 180, alignment: .trailing)
        case nil:
            EmptyView()
        }
    }
}
