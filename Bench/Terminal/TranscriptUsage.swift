import BenchKit
import Foundation

/// How full a Claude session's context window is, and how much it has
/// written, from the token counts in its transcript.
nonisolated struct ContextUsage: Equatable, Sendable {
    /// Tokens in the context as of Claude's latest reply.
    var contextTokens: Int
    /// Tokens Claude has written this session.
    var outputTokens: Int
    /// The model id, like "claude-opus-5-5".
    var model: String?
    /// The name from a /model switch since Claude's last reply, like
    /// "Opus 5.5". Replies carry the id, so this only bridges the gap.
    var switchedTo: String?
    /// The most the context has held, even before a /compact.
    var peakTokens = 0
    /// The window's size, for an agent whose session says it outright.
    var knownWindow: Int?
    /// The model's name as shown, for an agent that names models its own way.
    var shownName: String?

    /// Claude 5 models (other than Haiku) run with a 1M window in Claude Code.
    /// Older models default to 200k, so for those a session that has gone
    /// past 200k, or a default model set to a "[1m]" variant, means 1M.
    var window: Int {
        if let knownWindow { return knownWindow }
        return peakTokens > 200_000 || Self.defaultsToMillion || Self.hasMillionWindow(model) ? 1_000_000 : 200_000
    }

    /// True for model ids like "claude-opus-5-5" or "claude-fable-5-1":
    /// version 5 or later, and not Haiku.
    static func hasMillionWindow(_ model: String?) -> Bool {
        guard let model = model?.lowercased(), model.hasPrefix("claude-") else { return false }
        if model.contains("[1m]") { return true }
        let parts = model.dropFirst("claude-".count).split(separator: "-")
        guard let family = parts.first, family.allSatisfy(\.isLetter), family != "haiku",
              let major = parts.dropFirst().first.flatMap({ Int($0) }) else { return false }
        return major >= 5
    }

    /// True when ~/.claude/settings.json picks a 1M-context model, like "opus[1m]".
    static let defaultsToMillion: Bool = {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: file),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = settings["model"] as? String else { return false }
        return model.lowercased().contains("[1m]")
    }()
    var fraction: Double { min(1, Double(contextTokens) / Double(window)) }

    /// "Opus 5.5" from "claude-opus-5-5" (a trailing date is dropped).
    var modelName: String? {
        if let switchedTo { return switchedTo }
        return shownName ?? model.map(Self.modelName)
    }

    static func modelName(_ model: String) -> String {
        // "claude-opus-5-5[1m]" names the same model with a bigger window.
        let model = model.replacingOccurrences(of: #"\[[^\]]*\]$"#, with: "", options: .regularExpression)
        let parts: [String] = model.replacingOccurrences(of: "claude-", with: "")
            .split(separator: "-").map(String.init)
            .filter { !($0.count == 8 && $0.allSatisfy(\.isNumber)) }
        guard let family = parts.first else { return model }
        let version = parts[1...].joined(separator: ".")
        let name = String(family.prefix(1)).uppercased() + String(family.dropFirst())
        return version.isEmpty ? name : "\(name) \(version)"
    }

    /// "84k" or "1.2M".
    static func short(_ tokens: Int) -> String {
        switch tokens {
        case ..<1000: "\(tokens)"
        case ..<1_000_000: "\(Int((Double(tokens) / 1000).rounded()))k"
        default: String(format: "%.1fM", Double(tokens) / 1_000_000)
        }
    }
}

/// What Bench reads from a Claude transcript: token usage and the
/// checklist Claude keeps while it works.
nonisolated struct TranscriptInfo: Equatable, Sendable {
    var usage: ContextUsage?
    /// The model's name, like "Opus 5.5", even before Claude's first reply
    /// when you've picked one with /model.
    var model: String?
    /// The effort level set with /effort since the last model switch, like
    /// "high", and when.
    var effort: String?
    var effortAt: Date?
    var checklist: [ChecklistItem] = []
    /// When the checklist last changed.
    var checklistUpdatedAt: Date?
    /// Claude's latest tool calls, newest first.
    var trail: [ToolAction] = []
    /// What Claude last said along the way ("Reading the hover card now"),
    /// and when.
    var note: String?
    var noteAt: Date?
    /// When you last pressed Esc on Claude ("[Request interrupted by
    /// user]"). No hook fires for that, so it's the only sign the turn
    /// ended.
    var interruptedAt: Date?
    /// Every file Claude has edited or written in this session, by its
    /// full path, with when it last did.
    var editedFiles: [String: Date] = [:]
}

/// Keeps the last few tool calls from a transcript's main conversation.
/// Checklist updates are left out; the checklist shows those.
nonisolated struct ActionTrail: Sendable {
    static let limit = 5
    private(set) var actions: [ToolAction] = []
    private(set) var note: String?
    private(set) var noteAt: Date?

    private static let iso = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let skipped: Set<String> = ["TodoWrite", "TaskCreate", "TaskUpdate", "TaskList", "TaskGet", "ToolSearch"]

    mutating func apply(_ entry: [String: Any]) {
        guard entry["type"] as? String == "assistant", entry["isSidechain"] as? Bool != true,
              let message = entry["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return }
        let time = (entry["timestamp"] as? String).flatMap { try? Self.iso.parse($0) } ?? Date()
        let said = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if !said.isEmpty {
            note = String(ToolWording.oneLine(said).prefix(400))
            noteAt = time
        }
        for block in content where block["type"] as? String == "tool_use" {
            guard let id = block["id"] as? String, let name = block["name"] as? String,
                  !Self.skipped.contains(name), !actions.contains(where: { $0.id == id }) else { continue }
            let text = ToolWording.describe(tool: name, input: block["input"] as? [String: Any] ?? [:])
            actions.insert(ToolAction(id: id, text: text, at: time), at: 0)
        }
        if actions.count > Self.limit { actions.removeLast(actions.count - Self.limit) }
    }

    /// One tool call, already put into words by its agent's reader.
    mutating func add(id: String, text: String, at time: Date) {
        guard !actions.contains(where: { $0.id == id }) else { return }
        actions.insert(ToolAction(id: id, text: text, at: time), at: 0)
        if actions.count > Self.limit { actions.removeLast(actions.count - Self.limit) }
    }

    /// Something the agent said in words.
    mutating func say(_ text: String, at time: Date) {
        let line = ToolWording.oneLine(text)
        guard !line.isEmpty else { return }
        note = String(line.prefix(400))
        noteAt = time
    }
}

/// Reads token usage and checklists from transcripts as they grow. Only the
/// new part of each file is read, off the main thread.
final class TranscriptUsageReader: @unchecked Sendable {
    private struct FileState {
        var offset: UInt64 = 0
        /// Bytes after the last newline, kept until the line is complete.
        var partial = Data()
        var stats = SessionStats()
    }

    private let queue = DispatchQueue(label: "Bench.TranscriptUsage", qos: .utility)
    private var files: [String: FileState] = [:]  // only touched on `queue`

    /// Reads any new lines and calls back on the main thread with what the
    /// session's transcript says so far.
    func update(path: String, completion: @escaping @MainActor (TranscriptInfo) -> Void) {
        queue.async { [self] in
            var state = files[path] ?? FileState()
            Self.readNew(path: path, into: &state)
            files[path] = state
            let stats = state.stats
            let info = TranscriptInfo(usage: stats.seen.isEmpty ? nil : stats.usage, model: stats.usage.modelName,
                                      effort: stats.effort, effortAt: stats.effortAt,
                                      checklist: stats.checklist.items,
                                      checklistUpdatedAt: stats.checklist.updatedAt,
                                      trail: stats.trail.actions,
                                      note: stats.trail.note, noteAt: stats.trail.noteAt,
                                      interruptedAt: stats.interruptedAt,
                                      editedFiles: stats.editedFiles)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(info) } }
        }
    }

    /// Forgets files no session points at anymore.
    func keep(paths: Set<String>) {
        queue.async { [self] in
            for path in files.keys where !paths.contains(path) { files[path] = nil }
        }
    }

    /// How much is read at a time. The first look at a long transcript
    /// used to read all of it into memory at once: hundreds of megabytes
    /// for a session that has run for days.
    nonisolated private static let chunkSize = 4 << 20

    nonisolated private static func readNew(path: String, into state: inout FileState) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        let reader = Agents.transcripts(for: path)
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        if end < state.offset { state = FileState() }  // rewritten: start over
        guard end > state.offset else { return }
        try? handle.seek(toOffset: state.offset)
        while state.offset < end, let data = try? handle.read(upToCount: chunkSize), !data.isEmpty {
            state.offset += UInt64(data.count)
            let chunk = state.partial + data
            // Keep an unfinished last line for next time.
            guard let lastNewline = chunk.lastIndex(of: UInt8(ascii: "\n")) else {
                state.partial = chunk
                continue
            }
            state.partial = Data(chunk[chunk.index(after: lastNewline)...])
            reader.read(lines: Data(chunk[..<lastNewline]), into: &state.stats)
        }
    }
}

/// What Workbench keeps from a session as it's written: how full the
/// context is, the agent's checklist, its latest tool calls, the files it
/// has edited. An agent's reader fills it in a few lines at a time
/// (`AgentTranscripts.read(lines:into:)`).
nonisolated struct SessionStats: Sendable {
    /// Replies already counted. Some agents write a reply several times
    /// as it streams, so each message counts once.
    var seen: Set<String> = []
    var usage = ContextUsage(contextTokens: 0, outputTokens: 0)
    var checklist = ChecklistReplay()
    var trail = ActionTrail()
    var interruptedAt: Date?
    var editedFiles: [String: Date] = [:]
    var effort: String?
    var effortAt: Date?
}

/// Rebuilds Claude's checklist by replaying its task tool calls, in order:
/// TaskCreate adds an item (its number arrives with the tool's result),
/// TaskUpdate changes one, and the older TodoWrite replaces the whole list.
nonisolated struct ChecklistReplay: Sendable {
    private(set) var items: [ChecklistItem] = []
    private(set) var updatedAt: Date?
    /// Items created but not yet numbered, by the tool call that made them.
    private var unnumbered: [String: ChecklistItem] = [:]
    /// Tool calls already applied, since a call can appear on more than one line.
    private var applied: Set<String> = []

    private static let iso = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    mutating func apply(_ entry: [String: Any]) {
        let type = entry["type"] as? String
        let time = (entry["timestamp"] as? String).flatMap { try? Self.iso.parse($0) }
        guard let message = entry["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return }
        if type == "assistant" {
            for block in content where block["type"] as? String == "tool_use" {
                guard let id = block["id"] as? String, !applied.contains(id),
                      let name = block["name"] as? String,
                      let input = block["input"] as? [String: Any] else { continue }
                applied.insert(id)
                switch name {
                case "TaskCreate":
                    unnumbered[id] = ChecklistItem(id: id, title: Self.text(input["subject"]) ?? "Untitled step",
                                                   activeTitle: Self.text(input["activeForm"]), status: .pending)
                case "TaskUpdate":
                    update(input, at: time)
                case "TodoWrite":
                    replace(input["todos"] as? [[String: Any]] ?? [], at: time)
                default:
                    break
                }
            }
        } else if type == "user", let result = entry["toolUseResult"] as? [String: Any],
                  let task = result["task"] as? [String: Any], let number = Self.text(task["id"]) {
            // TaskCreate's result carries the item's number.
            for block in content where block["type"] as? String == "tool_result" {
                guard let callID = block["tool_use_id"] as? String, var item = unnumbered.removeValue(forKey: callID) else { continue }
                item.id = number
                // A step added after every earlier one is done starts a new
                // list, the way the terminal clears a finished one.
                if !items.isEmpty, items.allSatisfy({ $0.status == .completed }) { items.removeAll() }
                items.removeAll { $0.id == number }
                items.append(item)
                updatedAt = time ?? updatedAt
            }
        }
    }

    private mutating func update(_ input: [String: Any], at time: Date?) {
        guard let id = Self.text(input["taskId"]), let index = items.firstIndex(where: { $0.id == id }) else { return }
        if let status = input["status"] as? String {
            switch status {
            case "deleted":
                items.remove(at: index)
                updatedAt = time ?? updatedAt
                return
            case "in_progress":
                if items[index].status != .inProgress { items[index].startedAt = time }
                items[index].status = .inProgress
            case "completed":
                items[index].status = .completed
            case "pending":
                items[index].status = .pending
            default:
                break
            }
        }
        if let subject = Self.text(input["subject"]) { items[index].title = subject }
        if let active = Self.text(input["activeForm"]) { items[index].activeTitle = active }
        updatedAt = time ?? updatedAt
    }

    private mutating func replace(_ todos: [[String: Any]], at time: Date?) {
        let previous = items
        items = todos.enumerated().map { index, todo in
            let title = Self.text(todo["content"]) ?? "Untitled step"
            let status: ChecklistItem.Status = switch todo["status"] as? String {
            case "in_progress": .inProgress
            case "completed": .completed
            default: .pending
            }
            // Keep when a step started if it was already under way.
            let earlier = previous.first { $0.title == title && $0.status == .inProgress }
            return ChecklistItem(id: String(index + 1), title: title, activeTitle: Self.text(todo["activeForm"]),
                                 status: status, startedAt: status == .inProgress ? (earlier?.startedAt ?? time) : nil)
        }
        updatedAt = time ?? updatedAt
    }

    private static func text(_ value: Any?) -> String? {
        switch value {
        case let string as String: string.isEmpty ? nil : string
        case let number as NSNumber: number.stringValue
        default: nil
        }
    }
}
