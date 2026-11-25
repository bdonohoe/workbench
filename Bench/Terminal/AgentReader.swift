import BenchKit
import Foundation

/// Follows a session's subagents from their own transcripts, which Claude
/// Code keeps in a `subagents` folder next to the session's: what each is
/// doing now, how many steps it's taken, and whether it's done. Only the
/// new part of each file is read, off the main thread.
final class AgentReader: SubagentReading, @unchecked Sendable {
    nonisolated private struct FileState {
        var offset: UInt64 = 0
        var partial = Data()
        var steps = 0
        var action: String?
        var startedAt: Date?
    }

    private let queue = DispatchQueue(label: "Bench.AgentReader", qos: .utility)
    nonisolated(unsafe) private var files: [String: FileState] = [:]  // only touched on `queue`

    /// An agent that hasn't written anything in this long, and never said
    /// it finished, has stopped (Claude was interrupted, or quit).
    nonisolated private static let quiet: TimeInterval = 10 * 60
    /// The most kept per session; the newest ones.
    nonisolated private static let limit = 20

    /// Calls back on the main thread with the session's agents, oldest
    /// first. `since` is when Claude Code last started in the tab: agents
    /// that went quiet before then were stopped with it.
    func update(transcript: String, since: Date?, completion: @escaping @MainActor ([AgentStatus]) -> Void) {
        queue.async { [self] in
            let agents = read(folder: URL(fileURLWithPath: String(transcript.dropLast(".jsonl".count))).appendingPathComponent("subagents"),
                              since: since)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(agents) } }
        }
    }

    nonisolated private func read(folder: URL, since: Date?) -> [AgentStatus] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var agents: [AgentStatus] = []
        for name in names where name.hasSuffix(".meta.json") {
            let meta = folder.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: meta),
                  let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let toolUseID = info["toolUseId"] as? String else { continue }
            let log = folder.appendingPathComponent(String(name.dropLast(".meta.json".count)) + ".jsonl")
            var state = files[log.path] ?? FileState()
            Self.readNew(path: log.path, into: &state)
            files[log.path] = state
            let modified = (try? FileManager.default.attributesOfItem(atPath: log.path)[.modificationDate] as? Date)
                ?? (try? FileManager.default.attributesOfItem(atPath: meta.path)[.modificationDate] as? Date)
            let finished = info["finished"] as? Bool ?? false
            let recent = modified.map { Date().timeIntervalSince($0) < Self.quiet && $0 >= (since ?? .distantPast) } ?? false
            agents.append(AgentStatus(
                toolUseID: toolUseID, description: info["description"] as? String ?? "Subagent",
                type: info["agentType"] as? String, isFinished: finished, isRunning: !finished && recent,
                action: finished ? nil : state.action, steps: state.steps,
                startedAt: state.startedAt ?? modified, finishedAt: finished ? modified : nil))
        }
        return Array(agents.sorted { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }.suffix(Self.limit))
    }

    nonisolated private static let iso = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    nonisolated private static func readNew(path: String, into state: inout FileState) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        if end < state.offset { state = FileState() }
        guard end > state.offset else { return }
        try? handle.seek(toOffset: state.offset)
        guard let data = try? handle.readToEnd() else { return }
        state.offset += UInt64(data.count)
        var chunk = state.partial + data
        if let lastNewline = chunk.lastIndex(of: UInt8(ascii: "\n")) {
            state.partial = chunk[chunk.index(after: lastNewline)...]
            chunk = chunk[..<lastNewline]
        } else {
            state.partial = chunk
            return
        }
        for line in chunk.split(separator: UInt8(ascii: "\n")) {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if state.startedAt == nil, let time = entry["timestamp"] as? String {
                state.startedAt = try? iso.parse(time)
            }
            guard entry["type"] as? String == "assistant",
                  let blocks = (entry["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            for block in blocks where block["type"] as? String == "tool_use" {
                state.steps += 1
                state.action = ToolWording.describe(tool: block["name"] as? String ?? "", input: block["input"] as? [String: Any] ?? [:])
            }
        }
    }
}
