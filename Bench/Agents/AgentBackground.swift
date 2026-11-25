import BenchKit
import Foundation

/// The work an agent does for Workbench out of sight, without a tab:
/// one-off questions (recaps, splitting a message into tasks), side
/// questions about a conversation, checking who's signed in, and what its
/// tokens cost. Each agent's command-line tool has its own flags and its
/// own output for these, so they're all here.
nonisolated protocol AgentBackground: Sendable {
    var agent: AgentID { get }
    /// The program to run, found on your PATH.
    var program: String { get }

    // MARK: One-off questions

    /// How to ask one question with no tools, no settings and no saved
    /// session, so it only reads what it's given and leaves nothing
    /// behind. The question goes in on standard input.
    func oneShot(instructions: String, model: BackgroundModel, profile: ClaudeProfile) -> BackgroundCommand
    /// The reply in what that printed. Nil when it isn't in the agent's
    /// own format, and the text is the reply as it stands.
    func oneShotReply(in output: String) -> BackgroundReply?

    // MARK: Side questions

    /// How to ask a question about a session so far, in a copy of it that
    /// is thrown away, answered in one turn and streamed as it's written.
    func sideQuestion(_ prompt: String, sessionID: String, model: String?, profile: ClaudeProfile) -> BackgroundCommand
    /// What one line of that stream says.
    func sideQuestionEvent(in line: String) -> SideQuestionStream.Event?
    /// True for the line where the agent starts to use a tool, which is
    /// when a side question is stopped.
    func startsToolCall(_ line: String) -> Bool

    // MARK: The account

    /// Who's signed in, asked of the program at `path`. With a folder, the
    /// account kept there. Nil when the program can't say.
    func signInStatus(program path: String, folder: String?) -> ClaudeAccount.Status?
    /// Where plan limits come from, for an agent that has a plan.
    var planLimits: (any AgentPlanLimits)? { get }

    // MARK: Cost

    /// What a reply's token counts come to, at the model's prices.
    func tally(usage: [String: Any], model: String) -> UsageTally
}

/// Which model a background question wants, in the agent's own terms.
nonisolated enum BackgroundModel: Sendable {
    /// The agent's small, quick model, for a sentence or two.
    case small
}

/// A program's arguments and the changes to make to its environment.
nonisolated struct BackgroundCommand: Sendable {
    var arguments: [String]
    /// Set after the removals.
    var environment: [String: String] = [:]
    /// Variables that must not be passed on.
    var removing: [String] = []

    func apply(to environment: inout [String: String]) {
        for key in environment.keys where key.hasPrefix("BENCH_") { environment[key] = nil }
        for key in removing { environment[key] = nil }
        environment.merge(self.environment) { _, new in new }
    }
}

/// An agent's plan limits, from wherever it keeps them.
nonisolated protocol AgentPlanLimits: Sendable {
    /// The limits in the status line the agent passes its hooks.
    func limits(fromStatusLine limits: [String: Any]) -> [PlanLimit]
    /// Asks the account itself.
    func fetch(profile: ClaudeProfile) async -> PlanLimitsResult
}

nonisolated enum PlanLimitsResult: Sendable {
    case usage([PlanLimit])
    case rateLimited(retryAfter: TimeInterval?)
    /// Not signed in to a plan, or something else went wrong.
    case unavailable
}

extension Agents {
    /// An agent's background side. Claude's for one this version doesn't have.
    nonisolated static func background(_ id: AgentID) -> any AgentBackground {
        allBackgrounds.first { $0.agent == id } ?? ClaudeBackground()
    }

    nonisolated static var allBackgrounds: [any AgentBackground] { [ClaudeBackground(), CodexBackground()] }

    /// The agent that does Workbench's own background work, like recaps:
    /// the one you chose for new tabs.
    nonisolated static var backgroundAgent: AgentID { standardID() }
}
