import BenchKit
import Foundation
import Testing
@testable import Bench

/// The Mac app's other readers of a Claude transcript, run on recorded
/// sessions. Each is pinned to what it returns today, so gathering them
/// behind a provider can't quietly change a recap, a meter or a title.
@MainActor
struct ClaudeReadersGoldenTests {
    nonisolated private static let sessions = ["tools", "interactive"]
    private func path(_ session: String) -> String { Golden.fixture("claude/\(session).jsonl").path }

    @Test(arguments: sessions)
    func theLastThingClaudeSaid(session: String) throws {
        let whole = AgentStateWatcher.lastAssistantMessage(transcript: path(session)) ?? "(none)"
        let start = AgentStateWatcher.lastAssistantText(transcript: path(session)) ?? "(none)"
        try Golden.check("start: \(start)\n\nwhole:\n\(whole)\n", "claude/\(session).last-message.txt")
    }

    @Test(arguments: sessions)
    func theTurnARecapIsWrittenFrom(session: String) throws {
        // A session that ends on /compact has no turn left to recap.
        let text = Recaps.turn(transcript: path(session)).map { "used tools: \($0.usedTools)\n\n\($0.text)\n" } ?? "(no turn)\n"
        try Golden.check(text, "claude/\(session).recap-turn.txt")
    }

    @Test(arguments: sessions)
    func theSpendLedgersTotals(session: String) throws {
        let rows = ClaudeTranscripts().ledgerEntries(in: Golden.fixture("claude/\(session).jsonl"))
            .sorted { $0.bucket.model < $1.bucket.model }
            .map { entry -> String in
                let tally = entry.tally
                return "\(entry.bucket.model) in \(entry.bucket.folder): \(tally.requests) requests, in \(tally.input), "
                    + "cache write \(tally.cacheWrite), cache read \(tally.cacheRead), out \(tally.output), "
                    + String(format: "cost %.6f, uncached %.6f", tally.cost, tally.uncachedCost)
            }
        try Golden.check(rows.joined(separator: "\n") + "\n", "claude/\(session).ledger.txt")
    }

    @Test(arguments: sessions)
    func theQueueLeftForARestart(session: String) throws {
        let queue = RestartRecovery.queue(inTranscript: path(session))
        try Golden.check(queue.joined(separator: "\n") + "\n", "claude/\(session).queue.txt")
    }

    @Test(arguments: sessions)
    func thePastSessionsRow(session: String) throws {
        let file = Golden.fixture("claude/\(session).jsonl")
        let size = try #require(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let past = try #require(ClaudeTranscripts().pastSession(in: file, modified: Date(timeIntervalSince1970: 0), size: size))
        let text = """
            id: \(past.id)
            title: \(past.title ?? "(none)")
            first prompt: \(past.firstPrompt ?? "(none)")
            last prompt: \(past.lastPrompt ?? "(none)")
            branch: \(past.branch ?? "(none)")

            """
        try Golden.check(text, "claude/\(session).past-session.txt")
    }

    @Test(arguments: sessions)
    func whatTheMetersAndChecklistRead(session: String) async throws {
        let reader = TranscriptUsageReader()
        let transcript = path(session)
        let info = await withCheckedContinuation { done in reader.update(path: transcript) { done.resume(returning: $0) } }
        var lines = [
            "model: \(info.model ?? "(none)")",
            "model id: \(info.usage?.model ?? "(none)")",
            "context tokens: \(info.usage?.contextTokens ?? -1)",
            "output tokens: \(info.usage?.outputTokens ?? -1)",
            "peak tokens: \(info.usage?.peakTokens ?? -1)",
            "effort: \(info.effort ?? "(none)")",
            "interrupted: \(info.interruptedAt != nil)",
            "note: \(info.note ?? "(none)")",
            "checklist:",
        ]
        lines += info.checklist.map { "  [\($0.status.rawValue)] \($0.title)" }
        lines.append("trail:")
        lines += info.trail.map { "  \($0.text)" }
        lines.append("edited files:")
        lines += info.editedFiles.keys.sorted().map { "  \($0)" }
        try Golden.check(lines.joined(separator: "\n") + "\n", "claude/\(session).usage.txt")
    }

    @Test func theSubagentsOfASession() async throws {
        let reader = AgentReader()
        let transcript = path("tools")
        let agents = await withCheckedContinuation { done in
            reader.update(transcript: transcript, since: nil) { done.resume(returning: $0) }
        }
        let rows = agents.map {
            "\($0.toolUseID) | \($0.description) | \($0.type ?? "-") | finished \($0.isFinished) | \($0.steps) steps | \($0.action ?? "-")"
        }
        try Golden.check(rows.joined(separator: "\n") + "\n", "claude/tools.agents.txt")
    }
}
