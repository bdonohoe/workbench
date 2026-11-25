import BenchKit
import Foundation

/// Codex's session files: one `rollout-<time>-<session id>.jsonl` per
/// session, in a folder per day under `~/.codex/sessions`. Unlike Claude's
/// they aren't filed by project, so which folder a session ran in comes
/// from its first line (`CodexSessionIndex`).
nonisolated struct CodexTranscripts: AgentTranscripts {
    var agent: AgentID { .codex }
    var format: any TranscriptFormat { CodexTranscriptFormat() }

    /// Where the main account keeps everything: `$CODEX_HOME`, or `~/.codex`.
    static var home: URL { CodexProfile.defaultHome }

    /// Each account's sessions folder, the main one first.
    static var sessionsFolders: [URL] { CodexAccounts.all.map(\.sessionsFolder) }

    func owns(_ path: String) -> Bool {
        let file = URL(fileURLWithPath: path).standardizedFileURL
        return Self.sessionsFolders.contains { file.path.hasPrefix($0.standardizedFileURL.path + "/") }
            || (file.lastPathComponent.hasPrefix("rollout-") && file.pathExtension == "jsonl")
    }

    // MARK: Reading lines

    private static let event = Data(#""event_msg""#.utf8)

    /// The `event_msg` payloads in some lines, with when each was written.
    private static func events(in data: Data) -> [(payload: [String: Any], at: Date?)] {
        data.split(separator: UInt8(ascii: "\n")).compactMap { line in
            guard line.range(of: event) != nil,
                  let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  entry["type"] as? String == "event_msg",
                  let payload = entry["payload"] as? [String: Any] else { return nil }
            return (payload, (entry["timestamp"] as? String).flatMap(date))
        }
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    /// The end of a file, from a line start.
    private static func tail(of path: String, bytes: UInt64) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: end > bytes ? end - bytes : 0)
        guard var data = try? handle.readToEnd() else { return nil }
        if end > bytes, let newline = data.firstIndex(of: UInt8(ascii: "\n")) { data = Data(data[data.index(after: newline)...]) }
        return data
    }

    private static func said(_ item: [String: Any]) -> String {
        if let text = item["text"] as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let blocks = item["content"] as? [[String: Any]] ?? []
        return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: One session

    func lastMessage(in path: String) -> String? {
        guard let data = Self.tail(of: path, bytes: 1_000_000) else { return nil }
        for (payload, _) in Self.events(in: data).reversed() {
            if payload["type"] as? String == "task_complete", let text = payload["last_agent_message"] as? String, !text.isEmpty { return text }
            if payload["type"] as? String == "item_completed", let item = payload["item"] as? [String: Any],
               item["type"] as? String == "AgentMessage" {
                let text = Self.said(item)
                if !text.isEmpty { return text }
            }
        }
        return nil
    }

    func recapTurn(in path: String) -> RecapTurn? {
        guard let data = Self.tail(of: path, bytes: 4_000_000) else { return nil }
        var prompt: String?
        var steps: [String] = []
        var spoken: [String] = []
        let reader = CodexTranscriptFormat()
        for line in data.split(separator: UInt8(ascii: "\n")) {
            for message in reader.messages(in: Data(line), options: .init()) {
                switch message.role {
                case .user:
                    prompt = message.text
                    steps = []
                    spoken = []
                case .assistant: spoken.append(message.text)
                case .tool: steps.append(message.text)
                default: break
                }
            }
        }
        guard let prompt, !spoken.isEmpty || !steps.isEmpty else { return nil }
        func clip(_ text: String, _ limit: Int) -> String { text.count > limit ? String(text.prefix(limit)) + "…" : text }
        var text = "What the user asked:\n" + clip(prompt, 1500) + "\n\n"
        if !steps.isEmpty {
            let shown = steps.count > 80 ? Array(steps.prefix(30)) + ["(\(steps.count - 70) more steps)"] + Array(steps.suffix(40)) : steps
            text += "Steps Codex took:\n" + shown.map { "- " + clip($0, 160) }.joined(separator: "\n") + "\n\n"
        }
        if spoken.count > 1 {
            text += "What Codex said along the way:\n" + spoken.dropLast().suffix(6).map { "- " + clip($0, 300) }.joined(separator: "\n") + "\n\n"
        }
        if let last = spoken.last { text += "Codex's final reply:\n" + clip(last, 2500) }
        return RecapTurn(text: text, usedTools: !steps.isEmpty)
    }

    /// Codex holds queued messages in its terminal until it takes them,
    /// and writes nothing about them before then.
    func queuedMessages(in path: String) -> [String] { [] }

    func lastActivity(in file: URL) -> Date? {
        guard let data = Self.tail(of: file.path, bytes: 512_000) else { return nil }
        for (payload, at) in Self.events(in: data).reversed() {
            guard payload["type"] as? String == "item_completed", let item = payload["item"] as? [String: Any],
                  ["UserMessage", "AgentMessage"].contains(item["type"] as? String ?? "") else { continue }
            return at
        }
        return nil
    }

    func read(lines: Data, into stats: inout SessionStats) {
        for (payload, at) in Self.events(in: lines) {
            let time = at ?? Date()
            switch payload["type"] as? String {
            case "token_count":
                guard let info = payload["info"] as? [String: Any] else { continue }
                func tokens(_ usage: Any?, _ key: String) -> Int { ((usage as? [String: Any])?[key] as? NSNumber)?.intValue ?? 0 }
                let context = tokens(info["last_token_usage"], "input_tokens")
                stats.seen.insert("token_count")
                stats.usage.contextTokens = context
                stats.usage.peakTokens = max(stats.usage.peakTokens, context)
                stats.usage.outputTokens = tokens(info["total_token_usage"], "output_tokens")
                if let window = (info["model_context_window"] as? NSNumber)?.intValue, window > 0 { stats.usage.knownWindow = window }
            case "thread_settings_applied":
                guard let settings = payload["thread_settings"] as? [String: Any] else { continue }
                if let model = settings["model"] as? String {
                    stats.usage.model = model
                    stats.usage.shownName = CodexModels.name(model)
                }
                if let effort = settings["reasoning_effort"] as? String {
                    stats.effort = effort
                    stats.effortAt = time
                }
            case "turn_aborted":
                if payload["reason"] as? String == "interrupted" { stats.interruptedAt = time }
            case "item_completed":
                guard let item = payload["item"] as? [String: Any], let id = item["id"] as? String else { continue }
                switch item["type"] as? String {
                case "AgentMessage":
                    stats.trail.say(Self.said(item), at: time)
                case "FileChange":
                    for path in (item["changes"] as? [String: Any] ?? [:]).keys.sorted() {
                        stats.editedFiles[(path as NSString).standardizingPath] = time
                        stats.trail.add(id: "\(id)/\(path)", text: "Editing \((path as NSString).lastPathComponent)", at: time)
                    }
                case "CommandExecution":
                    let command = CodexTranscriptFormat.shellCommand(item["command"])
                    stats.trail.add(id: id, text: ToolWording.describe(tool: ToolKind.shell.name, input: ["command": command]), at: time)
                default:
                    break
                }
            default:
                break
            }
        }
    }

    func makeSubagentReader() -> (any SubagentReading)? { nil }

    // MARK: Past sessions

    /// Codex has one sign-in, so its sessions are listed once, under the
    /// main account, however many Claude accounts there are.
    func sessionFiles(forProject path: String, account: ClaudeProfile) -> [URL] {
        account.isMain ? CodexSessionIndex.shared.files(in: path) : []
    }

    func sessionFile(_ id: String, forProject path: String, account: ClaudeProfile) -> URL? {
        account.isMain ? CodexSessionIndex.shared.files(in: path).first { Self.sessionID(of: $0) == id } : nil
    }

    /// The id at the end of `rollout-2026-11-24T11-27-16-<id>.jsonl`: the
    /// last five dash-separated groups, a UUID.
    static func sessionID(of file: URL) -> String {
        let parts = file.deletingPathExtension().lastPathComponent.split(separator: "-")
        return parts.count >= 5 ? parts.suffix(5).joined(separator: "-") : file.deletingPathExtension().lastPathComponent
    }

    func pastSession(in file: URL, modified: Date, size: Int) -> PastSession? {
        guard let handle = FileHandle(forReadingAtPath: file.path) else { return nil }
        defer { try? handle.close() }
        // The first prompt comes after Codex's instructions, which are long.
        let head = (try? handle.read(upToCount: 512 * 1024)) ?? Data()
        var session = PastSession(id: Self.sessionID(of: file), modified: modified)
        session.agent = .codex
        func prompts(in data: Data) -> [String] {
            Self.events(in: data).compactMap { payload, _ in
                guard payload["type"] as? String == "item_completed", let item = payload["item"] as? [String: Any],
                      item["type"] as? String == "UserMessage" else { return nil }
                let line = ToolWording.oneLine(Self.said(item))
                guard !line.isEmpty else { return nil }
                return line.count > 300 ? String(line.prefix(299)) + "…" : line
            }
        }
        let first = prompts(in: head)
        session.firstPrompt = first.first
        session.lastPrompt = first.last
        if size > head.count, let tail = Self.tail(of: file.path, bytes: 384 * 1024), let last = prompts(in: tail).last {
            session.lastPrompt = last
        }
        if session.firstPrompt == nil { session.firstPrompt = session.lastPrompt }
        // A session where nothing was ever asked isn't worth listing.
        return session.firstPrompt == nil ? nil : session
    }

    func recentFolders() -> [String: Date] { CodexSessionIndex.shared.folders() }

    // MARK: Spend

    func allSessionFiles(account: ClaudeProfile) -> [URL] {
        account.isMain ? CodexSessionIndex.allFiles() : []
    }

    /// One session's tokens by day and model. Codex writes a record per
    /// reply, with what that reply used.
    func ledgerEntries(in file: URL) -> [UsageLedger.Entry] {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return [] }
        let record = Data(#""token_usage_record""#.utf8), settings = Data(#""thread_settings_applied""#.utf8)
        var model = "gpt"
        let folder = CodexSessionIndex.folder(of: file) ?? ""
        var totals: [UsageBucket: UsageTally] = [:]
        var seen = Set<String>()
        for line in data.split(separator: UInt8(ascii: "\n")) {
            let isRecord = line.range(of: record) != nil
            guard isRecord || line.range(of: settings) != nil,
                  let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let payload = entry["payload"] as? [String: Any] else { continue }
            if entry["type"] as? String == "event_msg" {
                if let name = (payload["thread_settings"] as? [String: Any])?["model"] as? String { model = name }
                continue
            }
            guard entry["type"] as? String == "token_usage_record", let usage = payload["usage"] as? [String: Any] else { continue }
            if let response = payload["response_id"] as? String, !seen.insert(response).inserted { continue }
            let date = (entry["timestamp"] as? String).flatMap(Self.date) ?? Date()
            let bucket = UsageBucket(day: UsageLedger.dayFormatter.string(from: date), model: model, folder: folder)
            totals[bucket, default: UsageTally()] += CodexBackground().tally(usage: usage, model: model)
        }
        return totals.map { UsageLedger.Entry(bucket: $0.key, tally: $0.value) }
    }
}

/// How Codex's model ids read in the app: "gpt-6.2-sol" is "GPT-6.2 Sol".
nonisolated enum CodexModels {
    static func name(_ model: String) -> String {
        let parts = model.split(separator: "-").map(String.init)
        guard let first = parts.first else { return model }
        var name = first.lowercased() == "gpt" ? "GPT" : first.prefix(1).uppercased() + first.dropFirst()
        var rest = Array(parts.dropFirst())
        // The version stays joined to the family: "GPT-6.2".
        if let version = rest.first, version.first?.isNumber == true {
            name += "-" + version
            rest.removeFirst()
        }
        return ([name] + rest.map { $0.prefix(1).uppercased() + $0.dropFirst() }).joined(separator: " ")
    }
}

/// Which folder each Codex session ran in. Codex files sessions by day,
/// so this reads the start of each file once (a session's folder never
/// changes) and remembers it for as long as the app runs.
nonisolated final class CodexSessionIndex: @unchecked Sendable {
    static let shared = CodexSessionIndex()

    private let lock = NSLock()
    private var known: [String: String?] = [:]  // by file path

    /// Every session file, from every account.
    static func allFiles() -> [URL] {
        var files: [URL] = []
        var seen = Set<String>()
        for folder in CodexTranscripts.sessionsFolders {
            // Two accounts can't share a folder, but a link could make them look like they do.
            guard seen.insert(folder.resolvingSymlinksInPath().path).inserted,
                  let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
            else { continue }
            for case let url as URL in walker where url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-") { files.append(url) }
        }
        return files
    }

    /// The folder in a session's first line. It's near the start, ahead
    /// of Codex's instructions, so a few KB is enough to find it.
    static func folder(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 8 * 1024) else { return nil }
        let text = String(decoding: head, as: UTF8.self)
        guard let match = text.firstMatch(of: #/"cwd"\s*:\s*"((?:[^"\\]|\\.)*)"/#) else { return nil }
        // Unescape through JSON, for a folder with a quote or backslash in its name.
        let quoted = "\"\(match.1)\""
        let path = (try? JSONSerialization.jsonObject(with: Data(quoted.utf8), options: .fragmentsAllowed)) as? String ?? String(match.1)
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func folder(for file: URL) -> String? {
        lock.lock()
        if let found = known[file.path] { lock.unlock(); return found }
        lock.unlock()
        let found = Self.folder(of: file)
        lock.lock()
        known[file.path] = .some(found)
        lock.unlock()
        return found
    }

    /// A project's session files.
    func files(in project: String) -> [URL] {
        let wanted = URL(fileURLWithPath: project).standardizedFileURL.path
        return Self.allFiles().filter { folder(for: $0) == wanted }
    }

    /// Every folder Codex has been used in, with when it last was.
    func folders() -> [String: Date] {
        var newest: [String: Date] = [:]
        for file in Self.allFiles() {
            guard let folder = folder(for: file),
                  let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { continue }
            if modified > (newest[folder] ?? .distantPast) { newest[folder] = modified }
        }
        // Codex's own folders, for any account, aren't projects.
        return newest.filter { !$0.key.contains("/.codex/") && !$0.key.contains("/.codex-") }
    }
}
