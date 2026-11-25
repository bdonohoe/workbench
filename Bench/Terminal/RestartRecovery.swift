import BenchKit
import Foundation
import Observation

/// Remembers which Claude tabs were in the middle of something when
/// Workbench quit, like for an update, so they can pick up where they were.
///
/// Quitting stops Claude mid-turn, and Claude Code doesn't carry on by
/// itself when its conversation resumes. So at quit this notes each busy
/// tab and anything still in its queue. After the relaunch, those tabs say
/// so, and Continue asks Claude to carry on and sends the queue again.
@Observable
final class RestartRecovery {
    static let shared = RestartRecovery()

    struct Stopped: Codable, Equatable {
        /// When Workbench quit.
        var at: Date
        /// It was waiting on you (a permission or a question), not working.
        var wasWaiting: Bool
        /// Messages you'd queued that Claude hadn't taken in yet.
        var queued: [String]
    }

    /// Tabs stopped by the last quit, until you continue, dismiss, or send
    /// something else.
    private(set) var stopped: [UUID: Stopped] = [:]

    private static let file = BenchPaths.support.appendingPathComponent("interrupted-tabs.json")

    private init() {
        // Read once: a later quit writes its own list.
        if let data = try? Data(contentsOf: Self.file),
           let saved = try? JSONDecoder().decode([UUID: Stopped].self, from: data) {
            // Older than a day is stale: you'll have moved on.
            stopped = saved.filter { Date().timeIntervalSince($0.value.at) < 86_400 }
        }
        try? FileManager.default.removeItem(at: Self.file)
    }

    /// Notes every busy Claude tab. Called as Workbench quits.
    func recordQuit(terminals: TerminalManager) {
        var list: [UUID: Stopped] = [:]
        let kept = terminals.tabsKeptThroughQuit()
        for (tabID, session) in terminals.claudeSessionsForQuit() {
            // The keeper keeps it running, so nothing stops.
            guard !kept.contains(tabID), session.isAgent, session.remoteHost == nil,
                  session.isWorking || session.claudeState == .waiting else { continue }
            let transcript = CompanionSnapshots.transcriptPath(tabID: tabID, terminals: terminals)
            list[tabID] = Stopped(at: .now, wasWaiting: session.claudeState == .waiting,
                                  queued: transcript.map(Self.queue(inTranscript:)) ?? [])
        }
        // Tabs from the quit before that you never got back to still count.
        for (tabID, old) in stopped where list[tabID] == nil { list[tabID] = old }
        if list.isEmpty {
            try? FileManager.default.removeItem(at: Self.file)
        } else if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: Self.file, options: .atomic)
        }
    }

    /// Notes a tab whose Claude stopped some other way than a quit, like
    /// its session keeper going away, if its hooks last said it was busy.
    /// Call before the tab starts again, which clears what the hooks wrote.
    func noteStopped(_ tabID: UUID) {
        let file = AgentSessions.stateFolder.appendingPathComponent(tabID.uuidString)
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let state = AgentState(rawValue: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              state != .done else { return }
        stopped[tabID] = Stopped(at: .now, wasWaiting: state == .waiting,
                                 queued: AgentSessions.transcriptPath(tabID: tabID).map(Self.queue(inTranscript:)) ?? [])
    }

    /// The tab's note, unless you've sent Claude something since.
    func stopped(tabID: UUID, lastPrompt: Date?) -> Stopped? {
        guard let note = stopped[tabID] else { return nil }
        if let lastPrompt, lastPrompt > note.at { return nil }
        return note
    }

    func dismiss(_ tabID: UUID) {
        stopped[tabID] = nil
    }

    /// Asks Claude to carry on, then sends the queued messages again, a
    /// moment apart so each lands in Claude's queue. Returns a problem if
    /// Claude isn't ready for messages yet.
    @discardableResult
    func continueTab(_ tabID: UUID, terminals: TerminalManager) -> String? {
        guard let note = stopped[tabID] else { return nil }
        let ask = note.wasWaiting
            ? "Workbench restarted while you were waiting on me, so that request was lost. Please pick up where you left off and ask again if you still need to."
            : "Workbench restarted while you were working, which stopped you partway through. Please pick up where you left off."
        if let problem = terminals.companionReply(ask, tabID: tabID, here: true) { return problem }
        stopped[tabID] = nil
        for (index, message) in note.queued.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5 * Double(index + 1)) { [weak terminals] in
                terminals?.companionReply(message, tabID: tabID, here: true)
            }
        }
        return nil
    }

    /// What's still in the agent's queue, from the end of the transcript.
    nonisolated static func queue(inTranscript path: String) -> [String] {
        Agents.transcripts(for: path).queuedMessages(in: path)
    }
}
