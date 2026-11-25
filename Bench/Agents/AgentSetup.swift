import BenchKit
import Foundation

/// Getting an agent onto a Mac: how to install it, how to sign in, and
/// whether it's ready. Setup and Settings show this for every agent, so
/// neither has to know one agent from another.
nonisolated struct AgentSetup: Identifiable, Sendable, Equatable {
    /// What's known about the agent on this Mac.
    enum State: Equatable, Sendable {
        case checking
        /// Installed and signed in. The version, when it says.
        case ready(version: String?)
        case signedOut
        case notInstalled

        var isReady: Bool { if case .ready = self { true } else { false } }
    }

    let id: AgentID
    /// "Claude": who you talk to.
    let name: String
    /// "Claude Code": the program.
    let product: String
    /// "Anthropic's coding agent."
    let maker: String
    let program: String
    let symbol: String
    /// A page about it, for anyone who wants to read first.
    let page: URL
    var state = State.checking

    /// Still being finished: it works, with some things left to its own
    /// terminal. Shown as "Beta", and never the one setup insists on.
    var isBeta: Bool { id == .codex }
    /// "Codex (Beta)", where the name stands alone.
    var title: String { isBeta ? "\(product) (Beta)" : product }

    /// What to run in a terminal to install it. Each is the way its
    /// maker says to.
    var installCommand: String {
        switch id {
        case .codex:
            // Homebrew when it's there, since npm needs Node as well.
            AgentPrograms.isInstalled("brew") || !AgentPrograms.isInstalled("npm") ? "brew install --cask codex" : "npm install -g @openai/codex"
        default:
            "curl -fsSL https://claude.ai/install.sh | bash"
        }
    }

    /// What installing needs that this Mac doesn't have, if anything.
    var installNeeds: String? {
        guard id == .codex, !AgentPrograms.isInstalled("brew"), !AgentPrograms.isInstalled("npm") else { return nil }
        return "This needs Homebrew, from brew.sh."
    }

    /// What to run to sign in.
    var signInCommand: String { id == .codex ? "\(program) login" : "\(program) auth login" }

    /// Every agent this version knows, in the order they're shown.
    static var all: [AgentSetup] {
        [AgentSetup(id: .claude, name: "Claude", product: "Claude Code", maker: "Anthropic's coding agent.", program: "claude",
                    symbol: "sparkle", page: URL(string: "https://claude.com/product/claude-code")!),
         AgentSetup(id: .codex, name: "Codex", product: "Codex", maker: "OpenAI's coding agent.", program: "codex",
                    symbol: "hexagon", page: URL(string: "https://developers.openai.com/codex/cli")!)]
    }

    /// Looks for the program and asks it who's signed in. Slow (it runs
    /// the program), so call it off the main thread.
    static func state(of id: AgentID) -> State {
        #if DEBUG
        // BENCH_AGENTS_MISSING=claude,codex and BENCH_AGENTS_SIGNED_OUT=codex
        // show those states, for checking the setup pages.
        let environment = ProcessInfo.processInfo.environment
        if environment["BENCH_AGENTS_MISSING"]?.split(separator: ",").contains(Substring(id.rawValue)) == true { return .notInstalled }
        if environment["BENCH_AGENTS_SIGNED_OUT"]?.split(separator: ",").contains(Substring(id.rawValue)) == true { return .signedOut }
        #endif
        let background = Agents.background(id)
        guard background.agent == id, let path = Tools.path(background.program) else { return .notInstalled }
        // An agent that can't say who's signed in counts as signed in.
        if background.signInStatus(program: path, folder: nil)?.loggedIn == false { return .signedOut }
        let version = Tools.run(path, ["--version"], environment: Tools.environment)?
            .split(whereSeparator: \.isWhitespace).first { $0.first?.isNumber == true }.map(String.init)
        return .ready(version: version)
    }

    /// Which agent new tabs should run, given what's ready: your choice
    /// while it's ready, or else the one that is.
    static func preferred(among agents: [AgentSetup], chosen: AgentID) -> AgentID {
        let ready = agents.filter(\.state.isReady).map(\.id)
        return ready.contains(chosen) ? chosen : ready.first ?? chosen
    }
}
