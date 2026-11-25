import Foundation

/// Codex's session files.
///
/// Codex writes a session as lines of JSON, each with a `type` and a
/// `payload`. Most are for the model (its instructions, raw tool calls).
/// What the chat shows comes from the `event_msg` lines Codex writes as
/// each thing finishes: a message of yours, something it said, a command
/// it ran, a file it changed. Those are turned into the same messages
/// Claude's sessions are, with Claude's names for the tools (`ToolKind`),
/// so nothing after this point knows which agent wrote the file.
public struct CodexTranscriptFormat: TranscriptFormat {
    public init() {}

    public func messages(in line: Data, options: TranscriptParser.Options) -> [TranscriptMessage] {
        // Cheap check first: nine lines in ten are something else.
        guard line.range(of: Data(#""event_msg""#.utf8)) != nil,
              let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              entry["type"] as? String == "event_msg",
              let payload = entry["payload"] as? [String: Any] else { return [] }
        let at = (entry["timestamp"] as? String).flatMap(Self.date)
        switch payload["type"] as? String {
        case "item_completed":
            guard let item = payload["item"] as? [String: Any] else { return [] }
            return Self.messages(for: item, at: at, options: options)
        case "task_complete":
            // How long the turn took, for turns long enough that you may
            // have looked away.
            guard options.keepsTurnTimes, let id = payload["turn_id"] as? String,
                  let milliseconds = (payload["duration_ms"] as? NSNumber)?.doubleValue,
                  milliseconds >= TurnTime.shortest * 1000 else { return [] }
            let seconds = milliseconds / 1000
            let rowID = "\(id)/worked"
            return [TranscriptMessage(id: rowID, role: .system, text: TurnTime.summary(id: rowID, worked: seconds), at: at, worked: seconds)]
        default:
            return []
        }
    }

    // MARK: Items

    private static func messages(for item: [String: Any], at: Date?, options: TranscriptParser.Options) -> [TranscriptMessage] {
        guard let id = item["id"] as? String else { return [] }
        switch item["type"] as? String {
        case "UserMessage":
            let text = said(item["content"])
            return text.isEmpty ? [] : [TranscriptMessage(id: id, role: .user, text: text, at: at)]
        case "AgentMessage", "Plan":
            let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? said(item["content"])
            return text.isEmpty ? [] : [TranscriptMessage(id: id, role: .assistant, text: text, at: at)]
        case "CommandExecution":
            return command(item, id: id, at: at, options: options)
        case "FileChange":
            return fileChanges(item, id: id, at: at, options: options)
        case "WebSearch":
            let query = item["query"] as? String ?? ""
            return [tool(.webSearch, id: id, input: ["query": query], detail: query, at: at)]
        case "ImageView":
            let path = item["path"] as? String ?? ""
            return [tool(.read, id: id, input: ["file_path": path], detail: path, at: at)]
        case "CollabAgentToolCall":
            let prompt = item["prompt"] as? String ?? ""
            return [tool(.agent, id: id, input: ["description": ToolWording.oneLine(prompt)], detail: nil, at: at)]
        case "McpToolCall":
            // Named the way Claude names a tool from an MCP server, which
            // is how the chat words one.
            let name = "mcp__\(item["server"] as? String ?? "server")__\(item["tool"] as? String ?? "tool")"
            var step = TranscriptMessage(id: id, role: .tool, text: ToolWording.literal(tool: name, input: [:]), toolName: name, at: at, toolUseID: id)
            if item["status"] as? String == "failed" { step.isError = true }
            return [step]
        case "ContextCompaction":
            return [TranscriptMessage(id: id, role: .system, text: "Conversation compacted", at: at)]
        default:
            // Reasoning, and anything a later Codex adds.
            return []
        }
    }

    /// The words in a message's content blocks.
    private static func said(_ content: Any?) -> String {
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tool(_ kind: ToolKind, id: String, input: [String: Any], detail: String?, at: Date?) -> TranscriptMessage {
        TranscriptMessage(id: id, role: .tool, text: ToolWording.describe(tool: kind.name, input: input),
                          detail: detail.flatMap { $0.isEmpty ? nil : $0 }, toolName: kind.name, at: at, toolUseID: id)
    }

    /// A command Codex ran, and (when results are kept) what it printed.
    private static func command(_ item: [String: Any], id: String, at: Date?, options: TranscriptParser.Options) -> [TranscriptMessage] {
        let text = shellCommand(item["command"])
        var messages = [tool(.shell, id: id, input: ["command": text], detail: text, at: at)]
        guard options.keepsResults else { return messages }
        let failed = item["status"] as? String == "failed" || ((item["exit_code"] as? NSNumber)?.intValue ?? 0) != 0
        messages.append(result(of: id, text: item["aggregated_output"] as? String ?? "", failed: failed, at: at))
        return messages
    }

    /// Codex runs a command through a shell: `["/bin/zsh", "-lc", "ls"]`.
    /// The last word is what it asked for.
    public static func shellCommand(_ command: Any?) -> String {
        if let text = command as? String { return text }
        guard let words = command as? [String], !words.isEmpty else { return "" }
        if words.count == 3, words[1].hasPrefix("-"), words[1].contains("c") { return words[2] }
        return words.joined(separator: " ")
    }

    /// A result as the chat keeps one: its last lines, each cut to a width.
    private static func result(of id: String, text: String, failed: Bool, at: Date?) -> TranscriptMessage {
        var lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        if lines.count > 12 { lines = Array(lines.suffix(12)) }
        let shown = lines.map { $0.count > 240 ? String($0.prefix(239)) + "…" : $0 }.joined(separator: "\n")
        return TranscriptMessage(id: "\(id)/result0", role: .tool, text: shown, at: at, resultOf: id, isError: failed)
    }

    /// One step per file a patch changed.
    private static func fileChanges(_ item: [String: Any], id: String, at: Date?, options: TranscriptParser.Options) -> [TranscriptMessage] {
        guard let changes = item["changes"] as? [String: Any] else { return [] }
        let failed = item["status"] as? String == "failed"
        var messages: [TranscriptMessage] = []
        for (index, path) in changes.keys.sorted().enumerated() {
            guard let change = changes[path] as? [String: Any] else { continue }
            let stepID = changes.count == 1 ? id : "\(id)/\(index)"
            let kind = change["type"] as? String
            let isNew = kind == "add"
            var step = tool(isNew ? .write : .edit, id: stepID, input: ["file_path": path], detail: path, at: at)
            var patch: EditPatch?
            if isNew, let content = change["content"] as? String {
                step.edit = ToolEdit.written(content)
                patch = EditPatch.written(content, path: path)
            } else if let diff = change["unified_diff"] as? String {
                patch = EditPatch.from(unifiedDiff: diff, path: path)
                step.edit = patch.map(ToolEdit.init(patch:))
            } else if kind == "delete", let content = change["content"] as? String {
                var lines = content.components(separatedBy: "\n")
                if lines.last == "" { lines.removeLast() }
                step.edit = ToolEdit(removed: Array(lines.prefix(ToolEdit.shownLines)), added: [], removedCount: lines.count, addedCount: 0, isNewFile: false)
            }
            messages.append(step)
            guard options.keepsResults else { continue }
            var done = result(of: stepID, text: failed ? (item["stderr"] as? String ?? "") : "", failed: failed, at: at)
            if options.keepsPatches, !failed { done.patch = patch }
            messages.append(done)
        }
        return messages
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

extension EditPatch {
    /// A new file, as one stretch of added lines.
    public static func written(_ content: String, path: String) -> EditPatch {
        var lines = content.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let kept = Array(lines.prefix(keptLines))
        return EditPatch(path: (path as NSString).standardizingPath, isNewFile: true,
                         hunks: kept.isEmpty ? [] : [Hunk(oldStart: 0, newStart: 1, lines: kept.map { "+" + $0 })],
                         additions: lines.count, deletions: 0, truncated: kept.count < lines.count)
    }

    /// The change in a unified diff: `@@ -1,2 +1,2 @@` and the lines under it.
    public static func from(unifiedDiff diff: String, path: String) -> EditPatch? {
        var hunks: [Hunk] = []
        for line in diff.components(separatedBy: "\n") {
            if line.hasPrefix("@@") {
                // "@@ -12,3 +14,4 @@": where the stretch starts on each side.
                let numbers = line.split(separator: " ").filter { $0.hasPrefix("-") || $0.hasPrefix("+") }
                    .map { Int($0.dropFirst().split(separator: ",").first ?? "") ?? 1 }
                hunks.append(Hunk(oldStart: numbers.first ?? 1, newStart: numbers.count > 1 ? numbers[1] : 1, lines: []))
            } else if !hunks.isEmpty, let first = line.first, first == " " || first == "+" || first == "-" {
                hunks[hunks.count - 1].lines.append(line)
            }
        }
        hunks.removeAll { $0.lines.isEmpty }
        guard !hunks.isEmpty else { return nil }
        let additions = hunks.reduce(0) { $0 + $1.lines.count { $0.hasPrefix("+") } }
        let deletions = hunks.reduce(0) { $0 + $1.lines.count { $0.hasPrefix("-") } }
        var kept: [Hunk] = []
        var room = keptLines
        for hunk in hunks where room > 0 {
            kept.append(Hunk(oldStart: hunk.oldStart, newStart: hunk.newStart, lines: Array(hunk.lines.prefix(room))))
            room -= hunk.lines.count
        }
        return EditPatch(path: (path as NSString).standardizingPath, isNewFile: false, hunks: kept,
                         additions: additions, deletions: deletions,
                         truncated: kept.reduce(0) { $0 + $1.lines.count } < hunks.reduce(0) { $0 + $1.lines.count })
    }
}

extension ToolEdit {
    /// The few lines the chat shows for a change, from the whole of it.
    public init(patch: EditPatch) {
        let lines = patch.hunks.flatMap(\.lines)
        let removed = lines.filter { $0.hasPrefix("-") }.map { String($0.dropFirst()) }
        let added = lines.filter { $0.hasPrefix("+") }.map { String($0.dropFirst()) }
        self.init(removed: Array(removed.prefix(Self.shownLines)), added: Array(added.prefix(Self.shownLines)),
                  removedCount: patch.deletions, addedCount: patch.additions, isNewFile: patch.isNewFile)
    }
}
