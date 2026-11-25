import BenchKit
import Foundation

/// Everything Workbench reads from an agent's session files. Each agent's
/// command-line tool writes its conversations in a layout of its own, so
/// this is the one place a feature gets at a session's contents: the chat,
/// recaps, the meters, past sessions and the spend ledger all ask here, and
/// none of them opens a session file itself.
///
/// Called from background queues, so nothing here touches the main actor.
nonisolated protocol AgentTranscripts: Sendable {
    /// The agent whose session files these are.
    var agent: AgentID { get }
    /// Reads one line of a session file into the messages the chat shows.
    var format: any TranscriptFormat { get }
    /// True for a session file this agent wrote, by where it is.
    func owns(_ path: String) -> Bool

    // MARK: One session

    /// The agent's last message in a session, whole.
    func lastMessage(in path: String) -> String?
    /// The latest turn, condensed for writing a recap from.
    func recapTurn(in path: String) -> RecapTurn?
    /// Messages still waiting in the agent's queue at the end of a session.
    func queuedMessages(in path: String) -> [String]
    /// When the last message in a session was written.
    func lastActivity(in file: URL) -> Date?
    /// Takes in more lines of a session as it's written: the context size,
    /// the checklist, the latest tool calls, edited files.
    func read(lines: Data, into stats: inout SessionStats)
    /// Follows a session's subagents, for an agent that has them.
    func makeSubagentReader() -> (any SubagentReading)?

    // MARK: Past sessions

    /// A project's session files under one account.
    func sessionFiles(forProject path: String, account: ClaudeProfile) -> [URL]
    /// Where one session of a project is kept, if this account has it.
    func sessionFile(_ id: String, forProject path: String, account: ClaudeProfile) -> URL?
    /// A past session's row: its title, first and last prompt, branch.
    func pastSession(in file: URL, modified: Date, size: Int) -> PastSession?
    /// Folders the agent has been used in, with when it last was. For
    /// suggesting projects to someone new to Workbench.
    func recentFolders() -> [String: Date]

    // MARK: Spend

    /// Every session file of an account, for totalling what it has used.
    func allSessionFiles(account: ClaudeProfile) -> [URL]
    /// One session's token totals, by day, model and folder.
    func ledgerEntries(in file: URL) -> [UsageLedger.Entry]
}

/// A turn boiled down to text a recap is written from.
nonisolated struct RecapTurn: Sendable {
    var text: String
    var usedTools: Bool
}

/// Follows the subagents of sessions as they run. Keeps its place in each
/// file, so there's one per provider for the life of the app.
nonisolated protocol SubagentReading: AnyObject, Sendable {
    /// Calls back on the main thread with the session's agents, oldest
    /// first. `since` is when the agent last started in the tab: subagents
    /// that went quiet before then were stopped with it.
    func update(transcript: String, since: Date?, completion: @escaping @MainActor ([AgentStatus]) -> Void)
}

extension Agents {
    /// The reader for a session file: the agent that wrote it, going by
    /// where the file is. Claude's for a file nobody claims, since every
    /// file was Claude's before there were other agents.
    nonisolated static func transcripts(for path: String) -> any AgentTranscripts {
        knownTranscripts.first { $0.owns(path) } ?? ClaudeTranscripts()
    }

    /// Every agent's reader: each provider's `transcripts`, listed here as
    /// well so that background queues can reach them.
    nonisolated static var knownTranscripts: [any AgentTranscripts] { [ClaudeTranscripts(), CodexTranscripts()] }

    /// The readers of the agents on offer. Past sessions, spend and
    /// project suggestions come from these, so an agent that's switched
    /// off adds nothing to them.
    nonisolated static var allTranscripts: [any AgentTranscripts] { knownTranscripts.filter { isOffered($0.agent) } }
}
