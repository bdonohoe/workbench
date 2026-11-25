import Foundation

/// One thing in a Claude conversation, as the phone shows it: something you
/// said, something Claude said, a tool it used, or a note from Claude Code.
public struct TranscriptMessage: Codable, Sendable, Hashable, Identifiable {
    /// `image` is a picture Claude looked at: a screenshot it took, a file
    /// it read, something it made along the way.
    public enum Role: String, Codable, Sendable { case user, assistant, tool, system, image }

    public var id: String
    public var role: Role
    /// Your words, Claude's Markdown, or a tool call in a few words
    /// ("Editing Theme.swift").
    public var text: String
    /// For a tool: what it was given, like the command or the file path.
    public var detail: String?
    public var toolName: String?
    public var at: Date?
    /// Pictures in the message: ones you attached, or ones Claude saw.
    public var images: [TranscriptImage]
    /// For an edit or a new file: what changed, to show as a small diff.
    public var edit: ToolEdit?
    /// For a tool call: Claude Code's id for it, which its result names.
    public var toolUseID: String?
    /// For a tool's result, when the reader keeps them: the call it answers.
    /// Folded into that call's step rather than shown on its own.
    public var resultOf: String?
    /// For a result: true when the tool failed.
    public var isError: Bool?
    /// For a message you sent while Claude was busy, before Claude takes it
    /// in: `added` when it joins the queue, `left` or `cleared` when it goes.
    /// Only sent to clients that ask for `CompanionFeature.queue`.
    public var queue: QueueEvent?
    /// For an Agent call: the subagent it started.
    public var agent: AgentCall?
    /// For a note that a background agent or command stopped. `text` is
    /// Claude Code's summary of it. Only sent to clients that ask for
    /// `CompanionFeature.agents`.
    public var notice: TaskNotice?
    /// For a call that publishes a page: its title so far (no link yet).
    /// For that call's result: the page, with its link.
    public var artifact: ArtifactLink?
    /// For Claude's plan: the whole plan, in Markdown. Set on the call that
    /// asks you to approve it, and on the Write that saves a plan file, so
    /// the plan can be read in the chat instead of only in the terminal.
    public var plan: String?
    /// For a command you ran yourself with a leading `!`: the command and,
    /// once it has run, what it printed.
    public var shell: ShellRun?
    /// For Claude Code's note at the end of a stretch of work: how long
    /// Claude worked, in seconds. `at` is when it finished. Only sent to
    /// clients that ask for `CompanionFeature.turnTimes`.
    public var worked: TimeInterval?
    /// For a slash command that prints something, like `/context`: the
    /// command, or what it printed. Only read on this Mac, for its own chat.
    public var command: CommandRun?
    /// For the result of an edit or a new file: what it changed in the
    /// file, whole. Only kept by readers that ask for it
    /// (`TranscriptParser.Options.keepsPatches`), and never sent to a phone.
    public var patch: EditPatch?

    public enum QueueEvent: String, Codable, Sendable, Hashable {
        /// You sent it while Claude was busy. Shown as queued.
        case added
        /// The queued message with this text was taken in or taken back.
        /// With no text, the oldest one.
        case left
        /// Everything queued was taken back at once.
        case cleared
    }

    public init(id: String, role: Role, text: String, detail: String? = nil, toolName: String? = nil, at: Date? = nil,
                images: [TranscriptImage] = [], edit: ToolEdit? = nil, toolUseID: String? = nil,
                resultOf: String? = nil, isError: Bool? = nil, queue: QueueEvent? = nil,
                agent: AgentCall? = nil, notice: TaskNotice? = nil, artifact: ArtifactLink? = nil, plan: String? = nil,
                shell: ShellRun? = nil, worked: TimeInterval? = nil, command: CommandRun? = nil,
                patch: EditPatch? = nil) {
        self.patch = patch
        self.worked = worked
        self.command = command
        self.id = id
        self.role = role
        self.text = text
        self.detail = detail
        self.toolName = toolName
        self.at = at
        self.images = images
        self.edit = edit
        self.toolUseID = toolUseID
        self.resultOf = resultOf
        self.isError = isError
        self.queue = queue
        self.agent = agent
        self.notice = notice
        self.artifact = artifact
        self.plan = plan
        self.shell = shell
    }

    private enum CodingKeys: String, CodingKey { case id, role, text, detail, toolName, at, images, edit, toolUseID, resultOf, isError, queue, agent, notice, artifact, plan, shell, worked, command, patch }

    // Lenient, so a phone and a Mac a version apart still understand each other.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        role = try c.decode(Role.self, forKey: .role)
        text = try c.decode(String.self, forKey: .text)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        toolName = try c.decodeIfPresent(String.self, forKey: .toolName)
        at = try c.decodeIfPresent(Date.self, forKey: .at)
        images = try c.decodeIfPresent([TranscriptImage].self, forKey: .images) ?? []
        edit = try? c.decodeIfPresent(ToolEdit.self, forKey: .edit)
        toolUseID = try c.decodeIfPresent(String.self, forKey: .toolUseID)
        resultOf = try c.decodeIfPresent(String.self, forKey: .resultOf)
        isError = try c.decodeIfPresent(Bool.self, forKey: .isError)
        queue = try? c.decodeIfPresent(QueueEvent.self, forKey: .queue)
        agent = try? c.decodeIfPresent(AgentCall.self, forKey: .agent)
        notice = try? c.decodeIfPresent(TaskNotice.self, forKey: .notice)
        artifact = try? c.decodeIfPresent(ArtifactLink.self, forKey: .artifact)
        plan = try? c.decodeIfPresent(String.self, forKey: .plan)
        shell = try? c.decodeIfPresent(ShellRun.self, forKey: .shell)
        worked = try? c.decodeIfPresent(TimeInterval.self, forKey: .worked)
        command = try? c.decodeIfPresent(CommandRun.self, forKey: .command)
        patch = try? c.decodeIfPresent(EditPatch.self, forKey: .patch)
    }
}

/// What an edit changed, trimmed to the lines that differ. Long changes
/// keep their first lines; the counts are always the whole change.
public struct ToolEdit: Codable, Sendable, Hashable {
    public var removed: [String]
    public var added: [String]
    public var removedCount: Int
    public var addedCount: Int
    /// True for a file Claude wrote from scratch.
    public var isNewFile: Bool

    /// Lines kept for showing, per side.
    public static let shownLines = 8

    public init(removed: [String], added: [String], removedCount: Int, addedCount: Int, isNewFile: Bool) {
        self.removed = removed
        self.added = added
        self.removedCount = removedCount
        self.addedCount = addedCount
        self.isNewFile = isNewFile
    }

    /// The lines that differ between two strings: what's left after the
    /// lines both share at the start and end.
    public static func between(_ old: String, _ new: String) -> ToolEdit {
        var a = old.components(separatedBy: "\n"), b = new.components(separatedBy: "\n")
        while let x = a.first, let y = b.first, x == y { a.removeFirst(); b.removeFirst() }
        while let x = a.last, let y = b.last, x == y { a.removeLast(); b.removeLast() }
        return ToolEdit(removed: Array(a.prefix(shownLines)), added: Array(b.prefix(shownLines)),
                        removedCount: a.count, addedCount: b.count, isNewFile: false)
    }

    /// Several edits to one file as one change.
    public static func combined(_ edits: [ToolEdit]) -> ToolEdit {
        ToolEdit(removed: Array(edits.flatMap(\.removed).prefix(shownLines)),
                 added: Array(edits.flatMap(\.added).prefix(shownLines)),
                 removedCount: edits.map(\.removedCount).reduce(0, +),
                 addedCount: edits.map(\.addedCount).reduce(0, +), isNewFile: false)
    }

    /// A whole file written at once.
    public static func written(_ content: String) -> ToolEdit {
        var lines = content.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return ToolEdit(removed: [], added: Array(lines.prefix(shownLines)), removedCount: 0, addedCount: lines.count, isNewFile: true)
    }

    /// The change an Edit, MultiEdit or Write call makes, from its input.
    public static func from(tool: String, input: [String: Any]) -> ToolEdit? {
        // Very long lines are cut, so one minified file can't swamp a message.
        func clip(_ edit: ToolEdit) -> ToolEdit {
            var edit = edit
            edit.removed = edit.removed.map { $0.count > 200 ? String($0.prefix(199)) + "…" : $0 }
            edit.added = edit.added.map { $0.count > 200 ? String($0.prefix(199)) + "…" : $0 }
            return edit
        }
        switch tool {
        case "Edit":
            guard let old = input["old_string"] as? String, let new = input["new_string"] as? String else { return nil }
            return clip(between(old, new))
        case "MultiEdit":
            let edits = (input["edits"] as? [[String: Any]] ?? []).compactMap { edit -> ToolEdit? in
                guard let old = edit["old_string"] as? String, let new = edit["new_string"] as? String else { return nil }
                return between(old, new)
            }
            return edits.isEmpty ? nil : clip(combined(edits))
        case "Write":
            return (input["content"] as? String).map { clip(written($0)) }
        case "Bash":
            // A file written with a here-document reads like a Write.
            guard let command = input["command"] as? String, let write = ShellStep.write(command) else { return nil }
            var edit = written(write.content)
            edit.isNewFile = !write.appends
            return clip(edit)
        default:
            return nil
        }
    }
}

/// What one edit did to a file, as Claude Code records it once the edit
/// has gone through: the lines around the change, with their numbers.
/// Unlike `ToolEdit`, which is a few lines for the chat, this is the whole
/// change, for reading through what a turn did.
public struct EditPatch: Codable, Sendable, Hashable {
    /// One changed stretch of the file.
    public struct Hunk: Codable, Sendable, Hashable {
        /// The first line it covers, from 1, before and after the edit.
        public var oldStart: Int
        public var newStart: Int
        /// Its lines as a unified diff has them: a space, "+" or "-" first.
        public var lines: [String]

        public init(oldStart: Int, newStart: Int, lines: [String]) {
            self.oldStart = oldStart
            self.newStart = newStart
            self.lines = lines
        }
    }

    /// The file's full path.
    public var path: String
    /// True for a file that wasn't there before.
    public var isNewFile: Bool
    public var hunks: [Hunk]
    /// Lines added and removed by the whole change, even when `hunks` was cut short.
    public var additions: Int
    public var deletions: Int
    /// The change was too long to keep whole, so `hunks` stops early.
    public var truncated: Bool

    /// Lines kept per edit. A generated file written in one go can run to
    /// tens of thousands, and every one would sit in memory with the chat.
    public static let keptLines = 3_000

    public init(path: String, isNewFile: Bool, hunks: [Hunk], additions: Int, deletions: Int, truncated: Bool = false) {
        self.path = path
        self.isNewFile = isNewFile
        self.hunks = hunks
        self.additions = additions
        self.deletions = deletions
        self.truncated = truncated
    }

    /// The patch in an edit's result, from the `toolUseResult` Claude Code
    /// saves beside it. Nil for results of anything else, and for edits
    /// that failed, which have none.
    public static func from(result: [String: Any]) -> EditPatch? {
        guard let path = result["filePath"] as? String, let recorded = result["structuredPatch"] as? [[String: Any]] else { return nil }
        var hunks = recorded.compactMap { hunk -> Hunk? in
            guard let lines = hunk["lines"] as? [String], !lines.isEmpty else { return nil }
            return Hunk(oldStart: (hunk["oldStart"] as? NSNumber)?.intValue ?? 1, newStart: (hunk["newStart"] as? NSNumber)?.intValue ?? 1,
                        lines: lines)
        }
        var isNewFile = false
        if hunks.isEmpty, result["type"] as? String == "create", let content = result["content"] as? String {
            // A new file has no patch, only what was written.
            var lines = content.components(separatedBy: "\n")
            if lines.last == "" { lines.removeLast() }
            isNewFile = true
            if !lines.isEmpty { hunks = [Hunk(oldStart: 0, newStart: 1, lines: lines.map { "+" + $0 })] }
        }
        guard !hunks.isEmpty || isNewFile else { return nil }
        let additions = hunks.reduce(0) { $0 + $1.lines.count { $0.hasPrefix("+") } }
        let deletions = hunks.reduce(0) { $0 + $1.lines.count { $0.hasPrefix("-") } }
        // Cut to what's worth keeping, a hunk at a time.
        var kept: [Hunk] = []
        var room = keptLines
        for hunk in hunks where room > 0 {
            kept.append(Hunk(oldStart: hunk.oldStart, newStart: hunk.newStart, lines: Array(hunk.lines.prefix(room))))
            room -= hunk.lines.count
        }
        return EditPatch(path: (path as NSString).standardizingPath, isNewFile: isNewFile, hunks: kept,
                         additions: additions, deletions: deletions,
                         truncated: kept.reduce(0) { $0 + $1.lines.count } < hunks.reduce(0) { $0 + $1.lines.count })
    }
}

/// A picture from the transcript. Claude Code stores them inline, so the
/// bytes come straight from the file.
///
/// Over the wire to a phone that asked for `CompanionFeature.imagePreviews`,
/// `data` is a smaller copy and `isPreview` is true; the whole picture
/// comes on request with `ClientMessage.image`.
public struct TranscriptImage: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var mediaType: String
    public var data: Data
    /// The whole picture's size in pixels, when known. With a preview,
    /// still the whole picture's, so a row can take its shape before
    /// anything is decoded.
    public var width: Int?
    public var height: Int?
    /// True when `data` is a smaller copy made for the wire.
    public var isPreview: Bool

    public init(id: String, mediaType: String, data: Data, width: Int? = nil, height: Int? = nil, isPreview: Bool = false) {
        self.id = id
        self.mediaType = mediaType
        self.data = data
        self.width = width
        self.height = height
        self.isPreview = isPreview
    }

    private enum CodingKeys: String, CodingKey { case id, mediaType, data, width, height, isPreview }

    // Lenient, so a phone and a Mac a version apart still understand each other.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        mediaType = try c.decode(String.self, forKey: .mediaType)
        data = try c.decode(Data.self, forKey: .data)
        width = try? c.decodeIfPresent(Int.self, forKey: .width)
        height = try? c.decodeIfPresent(Int.self, forKey: .height)
        isPreview = (try? c.decodeIfPresent(Bool.self, forKey: .isPreview)) ?? false
    }

    /// Width over height, when the size is known.
    public var aspectRatio: CGFloat? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return CGFloat(width) / CGFloat(height)
    }
}

/// Reads Claude Code's transcript lines (`~/.claude/projects/…/<session>.jsonl`).
/// The format is Claude Code's own and changes; anything unfamiliar is skipped.
public enum TranscriptParser {
    /// Options for reading a transcript.
    public struct Options: Sendable {
        /// Keep what commands printed and which tools failed, folded into
        /// their steps. Off for remote devices, which don't show them yet.
        public var keepsResults: Bool
        /// Keep messages you sent while Claude was busy, from when they're
        /// queued until Claude takes them in.
        public var keepsQueue: Bool
        /// Keep Claude Code's notes that a background agent or command
        /// stopped, as their own rows.
        public var keepsNotices: Bool
        /// Keep Claude Code's note of how long each stretch of work took,
        /// as a row after it.
        public var keepsTurnTimes: Bool
        /// Keep slash commands that print something, and what they
        /// printed, to show in the conversation.
        public var keepsCommands: Bool
        /// Keep what each edit changed, whole, on its result (so this
        /// needs `keepsResults` too). For reading through a turn's
        /// changes on this Mac; too much to send to a phone.
        public var keepsPatches: Bool

        public init(keepsResults: Bool = false, keepsQueue: Bool = false, keepsNotices: Bool = false, keepsTurnTimes: Bool = false,
                    keepsCommands: Bool = false, keepsPatches: Bool = false) {
            self.keepsPatches = keepsPatches
            self.keepsTurnTimes = keepsTurnTimes
            self.keepsCommands = keepsCommands
            self.keepsResults = keepsResults
            self.keepsQueue = keepsQueue
            self.keepsNotices = keepsNotices
        }
    }

    // ISO8601DateFormatter is safe to share between threads.
    nonisolated(unsafe) private static let dates: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let plainDates = ISO8601DateFormatter()

    /// The messages in one line of the transcript. Usually zero or one;
    /// a reply with several tool calls gives several.
    public static func messages(in line: Data, options: Options = Options()) -> [TranscriptMessage] {
        guard let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return [] }
        // Subagents keep their own side conversations; those aren't yours.
        guard entry["isSidechain"] as? Bool != true else { return [] }
        let id = entry["uuid"] as? String ?? UUID().uuidString
        let at = (entry["timestamp"] as? String).flatMap { dates.date(from: $0) ?? plainDates.date(from: $0) }
        switch entry["type"] as? String {
        case "user":
            if entry["isCompactSummary"] as? Bool == true {
                // The boundary below already marks it.
                return []
            }
            if options.keepsCommands, let text = (entry["message"] as? [String: Any])?["content"] as? String {
                if entry["isMeta"] as? Bool == true {
                    guard let markdown = CommandRun.markdownOutput(inTranscript: text) else { return [] }
                    return [TranscriptMessage(id: id, role: .user, text: "", at: at, command: CommandRun(name: "", output: markdown, isMarkdown: true))]
                }
                if let command = commandMessage(id: id, text: text, at: at) { return [command] }
            }
            guard entry["isMeta"] as? Bool != true, let message = entry["message"] as? [String: Any] else { return [] }
            if let notice = notice(id: id, content: message["content"], at: at) {
                return options.keepsNotices ? [notice] : []
            }
            var results = options.keepsResults ? toolResults(id: id, content: message["content"], at: at) : []
            // Claude Code saves one result per line, with the patch beside it.
            if options.keepsPatches, results.count == 1, results[0].isError != true,
               let saved = entry["toolUseResult"] as? [String: Any] {
                results[0].patch = EditPatch.from(result: saved)
            }
            return results + (userMessage(id: id, content: message["content"], at: at).map { [$0] } ?? [])
        case "assistant":
            guard let message = entry["message"] as? [String: Any],
                  let blocks = message["content"] as? [[String: Any]] else { return [] }
            var result: [TranscriptMessage] = []
            for (index, block) in blocks.enumerated() {
                let blockID = blocks.count == 1 ? id : "\(id)/\(index)"
                switch block["type"] as? String {
                case "text":
                    let text = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { result.append(TranscriptMessage(id: blockID, role: .assistant, text: text, at: at)) }
                case "tool_use":
                    let name = block["name"] as? String ?? ""
                    let input = block["input"] as? [String: Any] ?? [:]
                    let agent = name == "Agent" || name == "Task"
                        ? AgentCall(description: input["description"] as? String ?? "Subagent",
                                    type: input["subagent_type"] as? String,
                                    background: input["run_in_background"] as? Bool ?? false)
                        : nil
                    let artifact = ArtifactPublish.isPublish(tool: name, input: input)
                        ? ArtifactLink(url: "", title: ArtifactPublish.title(tool: name, input: input) ?? "", updated: at ?? .now)
                        : nil
                    // A file written from the shell is shown by its path, like a Write.
                    let shellWrite = name == "Bash" ? (input["command"] as? String).flatMap(ShellStep.write) : nil
                    result.append(TranscriptMessage(id: blockID, role: .tool,
                                                    text: artifact != nil ? "Publishing \(artifact!.title.isEmpty ? "a page" : artifact!.title)" : ToolWording.describe(tool: name, input: input),
                                                    detail: shellWrite?.path ?? ToolWording.detail(tool: name, input: input), toolName: name, at: at,
                                                    edit: ToolEdit.from(tool: name, input: input),
                                                    toolUseID: block["id"] as? String, agent: agent, artifact: artifact,
                                                    plan: PlanText.from(tool: name, input: input)))
                default:
                    break  // thinking, and whatever comes next
                }
            }
            return result
        case "attachment":
            // A message you send while Claude is busy is saved as a queued
            // command on the turn under way, not as a message of its own.
            // Ones from you count; Claude Code's own (task reports) don't.
            if let attachment = entry["attachment"] as? [String: Any], attachment["type"] as? String == "queued_command",
               let notice = notice(id: id, content: attachment["prompt"], at: at) {
                return options.keepsNotices ? [notice] : []
            }
            guard let attachment = entry["attachment"] as? [String: Any],
                  attachment["type"] as? String == "queued_command",
                  (attachment["origin"] as? [String: Any])?["kind"] as? String == "human" else { return [] }
            return userMessage(id: id, content: attachment["prompt"], at: at).map { [$0] } ?? []
        case "queue-operation":
            // Claude Code notes each change to its queue as it happens. The
            // message itself only reaches the transcript once Claude takes
            // it in, which can be a whole turn later.
            guard options.keepsQueue else { return [] }
            let content = entry["content"] as? String
            let queueID = "queue-\(entry["timestamp"] as? String ?? id)-\(entry["operation"] as? String ?? "")"
            switch entry["operation"] as? String {
            case "enqueue":
                // Claude Code queues its own notes too (task reports); those start with a tag.
                guard let content, !content.hasPrefix("<"),
                      var message = userMessage(id: queueID, content: content, at: at) else { return [] }
                message.queue = .added
                return [message]
            case "dequeue", "remove":
                return [TranscriptMessage(id: queueID, role: .system, text: content ?? "", at: at, queue: .left)]
            default:
                // Something that empties the queue, like taking it all back to edit.
                return [TranscriptMessage(id: queueID, role: .system, text: "", at: at, queue: .cleared)]
            }
        case "system":
            if entry["subtype"] as? String == "compact_boundary" {
                return [TranscriptMessage(id: id, role: .system, text: "Conversation compacted",
                                          detail: "Claude summarized the earlier messages to make room. It still knows what you were working on.", at: at)]
            }
            // What the terminal prints after a run ("Sautéed for 20m 23s"),
            // for runs long enough that you may have looked away.
            if options.keepsTurnTimes, entry["subtype"] as? String == "turn_duration",
               let milliseconds = (entry["durationMs"] as? NSNumber)?.doubleValue, milliseconds >= TurnTime.shortest * 1000 {
                let seconds = milliseconds / 1000
                return [TranscriptMessage(id: id, role: .system, text: TurnTime.summary(id: id, worked: seconds), at: at, worked: seconds)]
            }
            // Claude Code records some commands and what they print as
            // its own notes rather than as your messages.
            if options.keepsCommands, entry["subtype"] as? String == "local_command", let text = entry["content"] as? String,
               let command = commandMessage(id: id, text: text, at: at) {
                return [command]
            }
            return []
        default:
            return []
        }
    }

    /// A slash command you ran, or what one printed, from Claude Code's
    /// tagged entries. Nil for anything else.
    private static func commandMessage(id: String, text: String, at: Date?) -> TranscriptMessage? {
        if let run = CommandRun.command(inTranscript: text) {
            return TranscriptMessage(id: id, role: .user, text: run.typed, at: at, command: run)
        }
        if let printed = CommandRun.output(inTranscript: text) {
            return TranscriptMessage(id: id, role: .user, text: "", at: at, command: CommandRun(name: "", output: printed))
        }
        return nil
    }

    /// Claude Code's note that a background agent or command stopped, which
    /// it sends Claude as a tagged message.
    private static func notice(id: String, content: Any?, at: Date?) -> TranscriptMessage? {
        let text: String
        if let string = content as? String {
            text = string
        } else if let blocks = content as? [[String: Any]] {
            text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        } else {
            return nil
        }
        guard let (notice, summary) = TaskNotice.parse(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return TranscriptMessage(id: id, role: .system, text: summary, at: at, notice: notice)
    }

    /// Your prompt, or nil for things Claude Code puts in your messages
    /// itself: tool results, slash command output, pasted-image notes.
    private static func userMessage(id: String, content: Any?, at: Date?) -> TranscriptMessage? {
        var text: String
        var hasImage = false
        var pictures: [TranscriptImage] = []
        if let string = content as? String {
            text = string
        } else if let blocks = content as? [[String: Any]] {
            let results = blocks.filter { $0["type"] as? String == "tool_result" }
            if !results.isEmpty {
                // A tool's answer is Claude's business, unless it's a
                // picture: those are worth seeing.
                let pictures = results.enumerated().flatMap { index, result in
                    images(in: result["content"] as? [[String: Any]] ?? [], id: "\(id)/r\(index)")
                }
                guard !pictures.isEmpty else { return nil }
                return TranscriptMessage(id: id, role: .image, text: pictures.count == 1 ? "Claude looked at this" : "Claude looked at these",
                                         at: at, images: pictures)
            }
            text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
            pictures = images(in: blocks, id: id)
            hasImage = blocks.contains { $0["type"] as? String == "image" }
        } else {
            return nil
        }
        // Claude Code wraps pasted text in a tag. Keep the text, lose the tag,
        // so a message that starts with a paste isn't mistaken for one of
        // Claude Code's own notes below.
        text = text.replacingOccurrences(of: #"</?pasted_content[^>]*>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A command you ran with `!`, and then what it printed. The output
        // is its own entry here; `TranscriptTurn.group` folds it into the
        // command's turn.
        if let command = ShellRun.command(inTranscript: text) {
            let run = ShellRun(command: command)
            return TranscriptMessage(id: id, role: .user, text: run.typed, at: at, shell: run)
        }
        if let printed = ShellRun.output(inTranscript: text) {
            return TranscriptMessage(id: id, role: .user, text: "", at: at, shell: ShellRun(command: "", stdout: printed.stdout, stderr: printed.stderr))
        }
        if text.hasPrefix("<") || text.hasPrefix("Caveat:") || text.hasPrefix("[Request interrupted") { return nil }
        if isFromTeammate(text) { return nil }
        if !pictures.isEmpty {
            // The pictures show themselves; drop Claude Code's "[Image #1]" tags.
            text = text.replacingOccurrences(of: #"\[Image(?: #\d+)?\]\s*"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else if hasImage, !text.contains("[Image") {
            text = text.isEmpty ? "[Image]" : "[Image]\n" + text
        }
        guard !text.isEmpty || !pictures.isEmpty else { return nil }
        return TranscriptMessage(id: id, role: .user, text: text, at: at, images: pictures)
    }

    /// True for a message an agent-team teammate sent the lead. Claude Code
    /// saves those as user messages wrapped in `<teammate-message>` tags,
    /// sometimes after a line of its own or with several in one message,
    /// so the tag isn't always first.
    public static func isFromTeammate(_ text: String) -> Bool {
        text.contains(#/<teammate-message\s+teammate_id="/#)
    }

    /// Tool results as messages that name their call, cut to their last
    /// lines. The view decides which are worth showing (what a command
    /// printed, a tool that failed); a file's contents usually aren't.
    private static func toolResults(id: String, content: Any?, at: Date?) -> [TranscriptMessage] {
        guard let blocks = content as? [[String: Any]] else { return [] }
        return blocks.enumerated().compactMap { index, block in
            guard block["type"] as? String == "tool_result", let callID = block["tool_use_id"] as? String else { return nil }
            let failed = block["is_error"] as? Bool == true
            var text: String
            if let string = block["content"] as? String {
                text = string
            } else if let parts = block["content"] as? [[String: Any]] {
                text = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
            } else {
                text = ""
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Read before the text is cut down, which can lose the link.
            var artifact = !failed && text.contains("claude.ai/") ? ArtifactPublish.link(fromResult: text) : nil
            if artifact?.updated == .distantPast { artifact?.updated = at ?? .now }
            // The last lines are where results and errors usually are.
            var lines = text.components(separatedBy: "\n")
            if lines.count > 12 { lines = Array(lines.suffix(12)) }
            text = lines.map { $0.count > 240 ? String($0.prefix(239)) + "…" : $0 }.joined(separator: "\n")
            return TranscriptMessage(id: "\(id)/result\(index)", role: .tool, text: text, at: at,
                                     resultOf: callID, isError: failed, artifact: artifact)
        }
    }

    /// The base64 image blocks among some content blocks.
    private static func images(in blocks: [[String: Any]], id: String) -> [TranscriptImage] {
        blocks.enumerated().compactMap { index, block in
            guard block["type"] as? String == "image", let source = block["source"] as? [String: Any],
                  source["type"] as? String == "base64", let encoded = source["data"] as? String,
                  let data = Data(base64Encoded: encoded) else { return nil }
            return TranscriptImage(id: "\(id)/img\(index)", mediaType: source["media_type"] as? String ?? "image/png", data: data)
        }
    }
}

/// Tool calls in plain words. Used for the Overview on the Mac and the
/// conversation on the phone.
public enum ToolWording {
    public static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    private static func clipped(_ text: String, _ limit: Int) -> String {
        let line = oneLine(text)
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }

    private static func file(_ input: [String: Any], _ key: String) -> String? {
        (input[key] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    /// "Editing Theme.swift", "Showing recent commits". Shell commands use
    /// the description Claude gives them, or a plain reading of the command,
    /// so this is for showing progress. Use `literal` when you're being
    /// asked to allow a command and need to see exactly what it is.
    public static func describe(tool: String, input: [String: Any]) -> String {
        switch tool {
        case "Bash":
            if let description = (input["description"] as? String).map(oneLine), !description.isEmpty {
                return clipped(progressive(description), 80)
            }
            let command = input["command"] as? String ?? ""
            return ShellWording.describe(command) ?? literal(tool: tool, input: input)
        default:
            return literal(tool: tool, input: input)
        }
    }

    /// Like `describe`, but a shell command is shown as the command itself:
    /// "Running git push origin main".
    public static func literal(tool: String, input: [String: Any]) -> String {
        switch tool {
        case "Edit", "MultiEdit": return "Editing \(file(input, "file_path") ?? "a file")"
        case "Write": return "Writing \(file(input, "file_path") ?? "a file")"
        case "NotebookEdit": return "Editing \(file(input, "notebook_path") ?? "a notebook")"
        case "Read": return "Reading \(file(input, "file_path") ?? "a file")"
        case "Bash":
            let command = (input["command"] as? String ?? "a command").split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return "Running \(clipped(command, 60))"
        case "Grep": return "Searching for “\(clipped(input["pattern"] as? String ?? "", 40))”"
        case "Glob": return "Finding \(clipped(input["pattern"] as? String ?? "files", 40))"
        case "WebFetch": return "Reading \((input["url"] as? String).flatMap { URL(string: $0)?.host() } ?? "a web page")"
        case "WebSearch": return "Searching the web for “\(clipped(input["query"] as? String ?? "", 40))”"
        case "Task", "Agent": return "Running a subagent: \(clipped(input["description"] as? String ?? "", 40))"
        case "TodoWrite", "TaskCreate", "TaskUpdate": return "Updating its to-do list"
        case "AskUserQuestion": return "Asking you a question"
        case "ExitPlanMode": return "Asking you to approve a plan"
        default:
            if tool.hasPrefix("mcp__") { return "Using \(tool.split(separator: "_").last ?? "a tool")" }
            return tool.isEmpty ? "Working" : "Using \(tool)"
        }
    }

    /// Common verbs Claude starts a command's description with, and how
    /// they read while under way and once done.
    private static let verbs: [String: (now: String, then: String)] = [
        "add": ("Adding", "Added"), "apply": ("Applying", "Applied"), "build": ("Building", "Built"),
        "check": ("Checking", "Checked"), "clean": ("Cleaning", "Cleaned"), "clone": ("Cloning", "Cloned"),
        "commit": ("Committing", "Committed"), "compare": ("Comparing", "Compared"), "compile": ("Compiling", "Compiled"),
        "confirm": ("Confirming", "Confirmed"), "copy": ("Copying", "Copied"), "count": ("Counting", "Counted"),
        "create": ("Creating", "Created"), "delete": ("Deleting", "Deleted"), "diff": ("Diffing", "Diffed"),
        "display": ("Displaying", "Displayed"), "download": ("Downloading", "Downloaded"), "dump": ("Dumping", "Dumped"),
        "extract": ("Extracting", "Extracted"), "fetch": ("Fetching", "Fetched"), "find": ("Finding", "Found"),
        "format": ("Formatting", "Formatted"), "generate": ("Generating", "Generated"), "get": ("Getting", "Got"),
        "grep": ("Searching", "Searched"), "inspect": ("Inspecting", "Inspected"), "install": ("Installing", "Installed"),
        "kill": ("Stopping", "Stopped"), "launch": ("Launching", "Launched"), "lint": ("Linting", "Linted"),
        "list": ("Listing", "Listed"), "locate": ("Locating", "Located"), "look": ("Looking", "Looked"),
        "make": ("Making", "Made"), "merge": ("Merging", "Merged"), "move": ("Moving", "Moved"),
        "open": ("Opening", "Opened"), "print": ("Printing", "Printed"), "pull": ("Pulling", "Pulled"),
        "push": ("Pushing", "Pushed"), "query": ("Querying", "Queried"), "read": ("Reading", "Read"),
        "rebuild": ("Rebuilding", "Rebuilt"), "regenerate": ("Regenerating", "Regenerated"), "reload": ("Reloading", "Reloaded"),
        "remove": ("Removing", "Removed"), "rename": ("Renaming", "Renamed"), "restart": ("Restarting", "Restarted"),
        "resolve": ("Resolving", "Resolved"), "run": ("Running", "Ran"), "search": ("Searching", "Searched"),
        "set": ("Setting", "Set"), "show": ("Showing", "Showed"), "stage": ("Staging", "Staged"),
        "start": ("Starting", "Started"), "stop": ("Stopping", "Stopped"), "switch": ("Switching", "Switched"),
        "take": ("Taking", "Took"), "test": ("Testing", "Tested"), "trace": ("Tracing", "Traced"),
        "update": ("Updating", "Updated"), "upload": ("Uploading", "Uploaded"), "verify": ("Verifying", "Verified"),
        "view": ("Viewing", "Viewed"), "wait": ("Waiting", "Waited"), "write": ("Writing", "Wrote"),
        "edit": ("Editing", "Edited"), "use": ("Using", "Used"), "ask": ("Asking", "Asked"),
        "capture": ("Capturing", "Captured"), "fix": ("Fixing", "Fixed"), "map": ("Mapping", "Mapped"), "rewire": ("Rewiring", "Rewired"), "wire": ("Wiring", "Wired"), "replace": ("Replacing", "Replaced"), "revert": ("Reverting", "Reverted"), "save": ("Saving", "Saved"), "rerun": ("Rerunning", "Reran"), "retry": ("Retrying", "Retried"), "tag": ("Tagging", "Tagged"), "package": ("Packaging", "Packaged"), "sign": ("Signing", "Signed"), "archive": ("Archiving", "Archived"), "screenshot": ("Screenshotting", "Screenshotted"), "scan": ("Scanning", "Scanned"), "close": ("Closing", "Closed"), "reset": ("Resetting", "Reset"), "seed": ("Seeding", "Seeded"), "simulate": ("Simulating", "Simulated"), "measure": ("Measuring", "Measured"), "benchmark": ("Benchmarking", "Benchmarked"), "publish": ("Publishing", "Published"), "deploy": ("Deploying", "Deployed"), "note": ("Noting", "Noted"), "record": ("Recording", "Recorded"), "try": ("Trying", "Tried"),
    ]

    /// "Show recent commits" becomes "Showing recent commits". Wording
    /// that doesn't start with a known verb is left alone.
    static func progressive(_ text: String) -> String {
        let first = text.prefix { !$0.isWhitespace }
        guard let verb = verbs[first.lowercased()] else { return text.prefix(1).uppercased() + text.dropFirst() }
        return verb.now + text.dropFirst(first.count)
    }

    /// The same action, finished: "Showing recent commits" becomes
    /// "Showed recent commits".
    public static func past(_ text: String) -> String {
        let first = text.prefix { !$0.isWhitespace }
        guard let verb = verbs.values.first(where: { $0.now == first }) else { return text }
        return verb.then + text.dropFirst(first.count)
    }

    /// Like `past`, and also the verbs Claude joins on with "and" or a
    /// comma: "Running tests and commit" becomes "Ran tests and committed".
    public static func pastClauses(_ text: String) -> String {
        let done = past(text)
        guard done != text else { return text }
        var words = done.components(separatedBy: " ")
        for index in words.indices.dropFirst() {
            let previous = words[index - 1]
            guard previous == "and" || previous == "then" || previous.hasSuffix(",") else { continue }
            let word = words[index]
            let bare = word.trimmingCharacters(in: .punctuationCharacters)
            guard let verb = verbs[bare], bare == bare.lowercased() else { continue }
            words[index] = word.replacingOccurrences(of: bare, with: verb.then.lowercased())
        }
        return words.joined(separator: " ")
    }

    /// The main thing a tool was given, for when you tap a tool row.
    public static func detail(tool: String, input: [String: Any]) -> String? {
        func clip(_ text: String?, _ limit: Int = 600) -> String? {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
        }
        switch tool {
        case "Bash": return clip(input["command"] as? String)
        case "Edit", "MultiEdit", "Write", "Read": return clip(input["file_path"] as? String)
        case "NotebookEdit": return clip(input["notebook_path"] as? String)
        case "Grep":
            let pattern = input["pattern"] as? String ?? ""
            let path = input["path"] as? String
            return clip(path.map { "\(pattern) in \($0)" } ?? pattern)
        case "Glob": return clip(input["pattern"] as? String)
        case "WebFetch": return clip(input["url"] as? String)
        case "WebSearch": return clip(input["query"] as? String)
        case "Task", "Agent": return clip(input["prompt"] as? String, 400)
        case "AskUserQuestion":
            let questions = (input["questions"] as? [[String: Any]])?.compactMap { $0["question"] as? String }
            return clip(questions?.joined(separator: "\n"))
        default:
            guard !input.isEmpty, let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]) else { return nil }
            return clip(String(decoding: data, as: UTF8.self), 300)
        }
    }
}


/// Claude's plans, which Claude Code saves as Markdown files in a `plans`
/// folder of its config (`~/.claude/plans`, or wherever CLAUDE_CONFIG_DIR
/// points) before asking you to approve them.
public enum PlanText {
    /// Plans longer than this are cut, so one can't swamp a message.
    static let limit = 60_000

    /// True for a path in a Claude Code plans folder.
    public static func isPlanFile(_ path: String?) -> Bool {
        guard let path else { return false }
        return path.hasSuffix(".md") && (path as NSString).deletingLastPathComponent.hasSuffix("/plans")
    }

    /// The plan a tool call carries: the approval call's own plan, or what a
    /// Write puts in a plan file.
    static func from(tool: String, input: [String: Any]) -> String? {
        let text: String?
        switch tool {
        case "ExitPlanMode": text = input["plan"] as? String
        case "Write" where isPlanFile(input["file_path"] as? String): text = input["content"] as? String
        default: text = nil
        }
        return text.flatMap(clipped)
    }

    static func clipped(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > limit ? String(trimmed.prefix(limit - 1)) + "…" : trimmed
    }

    /// The plan to show beside the question cards, when they're Claude
    /// asking you to approve one: the newest plan in the conversation.
    public static func forApproval(_ questions: [CompanionQuestion], in messages: [TranscriptMessage]?) -> String? {
        guard questions.count == 1, questions[0].question == CompanionQuestion.planApprovalText else { return nil }
        return messages?.last { $0.toolName == "ExitPlanMode" && $0.plan != nil }?.plan
    }

    /// Fills in the plan on approval calls that came without one, from the
    /// plan file Claude last wrote or edited. `lastFile` carries that file
    /// from one batch of messages to the next. The file is read as it is
    /// now, which is the plan being approved for the newest call.
    public static func fill(_ messages: inout [TranscriptMessage], lastFile: inout String?,
                            read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }) {
        for index in messages.indices {
            let message = messages[index]
            guard message.role == .tool else { continue }
            if ["Write", "Edit", "MultiEdit"].contains(message.toolName ?? ""), isPlanFile(message.detail) {
                lastFile = message.detail
            } else if message.toolName == "ExitPlanMode", message.plan == nil, let file = lastFile {
                messages[index].plan = read(file).flatMap(clipped)
            }
        }
    }
}
