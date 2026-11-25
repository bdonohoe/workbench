import Foundation

extension CompanionFeature {
    /// The lock screen dashboard: one Live Activity for every session,
    /// started from the phone (`ClientMessage.registerDashboard`).
    public static let dashboard = "dashboard"
    /// Turning kinds of notifications off for one phone.
    public static let notificationPrefs = "notificationPrefs"
    /// Token use and what it would cost at API prices, from the Mac's
    /// Usage page.
    public static let usage = "usage"
    /// Splitting one message into tasks for several projects on the Mac,
    /// checking them on the phone, and starting an agent for each.
    public static let sendTasks = "sendTasks"
    /// Refreshing a project's changes and picking the branch they're
    /// compared against, from the Changes panel's header.
    public static let branchControls = "branchControls"
    /// Closing a Claude tab, and cleaning up or discarding an agent's
    /// worktree, from another device.
    public static let agentLifecycle = "agentLifecycle"
    /// Running and stopping a project's tab shortcuts, like its dev
    /// server, from another device.
    public static let shortcuts = "shortcuts"
    /// Queuing prompts from the phone, sealed on the relay, for a Mac that
    /// is asleep to pick up when it wakes.
    public static let offlineQueue = "offlineQueue"
    /// `/btw` side questions: asked with `ClientMessage.askSideQuestion`,
    /// answered as they come in with `ServerMessage.sideQuestion`.
    public static let sideQuestions = "sideQuestions"
}

/// One of a project's tab shortcuts on the Mac, like its dev server or
/// `make watch`, and whether a tab is running it now.
public struct CompanionShortcut: Codable, Sendable, Hashable, Identifiable {
    /// The shortcut's id on the Mac, or "dev" for the dev server button.
    public var id: String
    public var name: String
    /// An SF Symbol.
    public var symbol: String
    public var command: String
    public var isRunning: Bool
    /// The ports its running tabs are listening on.
    public var ports: [Int]
    /// Shown in the Mac's tab bar, not just its + menu.
    public var showsInTabBar: Bool

    public init(id: String, name: String, symbol: String, command: String, isRunning: Bool, ports: [Int] = [],
                showsInTabBar: Bool = true) {
        self.showsInTabBar = showsInTabBar
        self.id = id
        self.name = name
        self.symbol = symbol
        self.command = command
        self.isRunning = isRunning
        self.ports = ports
    }
}

/// Whether an agent's worktree can be cleaned up, and what would be lost.
/// Sent for worktrees whose pull request merged.
public enum CompanionCleanup: String, Codable, Sendable, Hashable {
    /// Nothing would be lost.
    case ready
    case uncommitted
    case unpushed
    /// Workbench couldn't check.
    case unknown
}

/// The Mac's answer to `ClientMessage.splitTasks`: the tasks Claude found,
/// the projects they can go to, and the branch names each project already
/// has, so the phone can flag clashes before asking the Mac to start.
public struct TaskSplitResult: Codable, Sendable, Hashable {
    public var message: String
    public var tasks: [DraftTask]
    public var projects: [SplitProject]
    public var existingBranches: [UUID: [String]]
    /// Why there are no tasks, when the split didn't work.
    public var problem: String?

    public init(message: String, tasks: [DraftTask], projects: [SplitProject], existingBranches: [UUID: [String]], problem: String? = nil) {
        self.message = message
        self.tasks = tasks
        self.projects = projects
        self.existingBranches = existingBranches
        self.problem = problem
    }
}

/// The kinds of notifications the Mac sends a phone, each of which can be
/// turned off.
public enum CompanionNotificationKind: String, Codable, Sendable, CaseIterable, Identifiable {
    /// morningSummary is no longer sent. It stays so older Macs and
    /// phones still read each other's settings.
    case needsYou, finished, checks, deploys, morningSummary
    /// Sent when Claude runs `bench notify`.
    case messages

    public var id: String { rawValue }

    /// The kinds you can turn on and off.
    public static var choices: [CompanionNotificationKind] { allCases.filter { $0 != .morningSummary } }

    public var title: String {
        switch self {
        case .needsYou: "An agent needs you"
        case .finished: "An agent finished"
        case .checks: "Pull request checks"
        case .deploys: "Deploys"
        case .morningSummary: "Morning summary"
        case .messages: "Messages from agents"
        }
    }

    public var detail: String {
        switch self {
        case .needsYou: "A permission, a question, or a plan to approve."
        case .finished: "With a recap of what got done."
        case .checks: "When a pull request's checks pass or fail."
        case .deploys: "When a merged pull request finishes deploying, or fails."
        case .morningSummary: "What got done across your projects since the day before."
        case .messages: "When you ask an agent to let you know about something."
        }
    }
}

/// What the Mac's Usage page shows, for the phone: the last 30 days by
/// day and model family, and the totals by model.
public struct CompanionUsage: Codable, Sendable, Hashable {
    public struct Day: Codable, Sendable, Hashable {
        /// "2026-10-31".
        public var day: String
        /// Cost at API prices by model family ("Opus", "Fable", ...).
        public var cost: [String: Double]
        public var tokens: Int

        public init(day: String, cost: [String: Double], tokens: Int) {
            self.day = day
            self.cost = cost
            self.tokens = tokens
        }

        public var total: Double { cost.values.reduce(0, +) }
    }

    public struct Model: Codable, Sendable, Hashable {
        /// "Opus 5.5".
        public var name: String
        /// "Opus".
        public var family: String
        public var cost: Double
        public var tokens: Int

        public init(name: String, family: String, cost: Double, tokens: Int) {
            self.name = name
            self.family = family
            self.cost = cost
            self.tokens = tokens
        }
    }

    /// Oldest first, one per day, including days with nothing.
    public var days: [Day]
    /// Over the 30 days, most expensive first.
    public var models: [Model]
    /// What prompt caching saved over the 30 days, at API prices.
    public var cacheSavings: Double
    public var updated: Date
    /// True when Claude Code on the Mac uses an API key or cloud provider,
    /// which bills by the token, so these numbers are close to the bill.
    /// Nil from Macs that don't say.
    public var paysPerToken: Bool?
    /// "Amazon Bedrock" and the like, when that's who bills.
    public var provider: String?

    public init(days: [Day], models: [Model], cacheSavings: Double, updated: Date,
                paysPerToken: Bool? = nil, provider: String? = nil) {
        self.days = days
        self.models = models
        self.cacheSavings = cacheSavings
        self.updated = updated
        self.paysPerToken = paysPerToken
        self.provider = provider
    }

    /// The cost over the most recent `count` days.
    public func cost(lastDays count: Int) -> Double {
        days.suffix(count).reduce(0) { $0 + $1.total }
    }

    public func tokens(lastDays count: Int) -> Int {
        days.suffix(count).reduce(0) { $0 + $1.tokens }
    }
}

/// The Mac's morning summary: a line per project, and anything left open.
/// No longer sent; kept so a phone can still read an older Mac's message.
public struct CompanionMorningSummary: Codable, Sendable, Hashable {
    public struct Line: Codable, Sendable, Hashable {
        public var project: String?
        public var text: String

        public init(project: String?, text: String) {
            self.project = project
            self.text = text
        }
    }

    public var written: Date
    public var since: Date
    public var lines: [Line]

    public init(written: Date, since: Date, lines: [Line]) {
        self.written = written
        self.since = since
        self.lines = lines
    }
}

/// How a merged pull request's deploy went, for the project list.
public struct CompanionDeploy: Codable, Sendable, Hashable {
    public enum State: String, Codable, Sendable { case deploying, succeeded, failed }

    public var state: State
    public var prNumber: Int
    /// Where it deploys, like "birchfeed / production".
    public var place: String?
    public var url: URL?

    public init(state: State, prNumber: Int, place: String?, url: URL?) {
        self.state = state
        self.prNumber = prNumber
        self.place = place
        self.url = url
    }
}

/// The one thing a quiet project's card says under its name, most useful
/// first: trouble, then a deploy in flight, then the pull request, then a
/// branch that isn't the default. Nil for a project with nothing going on.
/// The Mac's sidebar uses the same order.
public enum CompanionProjectStatus: Hashable, Sendable {
    case checksFailing(CompanionPullRequest)
    case deployFailed(CompanionDeploy)
    case deploying(CompanionDeploy)
    case pullRequest(CompanionPullRequest)
    case branch(String)
}

extension CompanionProject {
    public var status: CompanionProjectStatus? {
        let openPR = pullRequest.flatMap { $0.state == .open || $0.state == .draft ? $0 : nil }
        if let openPR, openPR.checks == .failing { return .checksFailing(openPR) }
        if let deploy, deploy.state == .failed { return .deployFailed(deploy) }
        if let deploy, deploy.state == .deploying { return .deploying(deploy) }
        if let openPR { return .pullRequest(openPR) }
        // A worktree is named by its branch, so its finished PR says more.
        if isWorktree, let pullRequest { return .pullRequest(pullRequest) }
        if !isWorktree, let branch, branch != (defaultBranch ?? ""), !(defaultBranch == nil && (branch == "main" || branch == "master")) {
            return .branch(branch)
        }
        return nil
    }
}
