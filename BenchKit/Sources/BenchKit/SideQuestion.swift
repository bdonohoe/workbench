import Foundation

/// A question asked with `/btw`: answered from what Claude already knows
/// in the conversation, without being added to it. Claude Code shows
/// these in a pop-up over its terminal and never writes them to the
/// transcript, so Bench asks them itself, in a copy of the conversation
/// that's thrown away afterwards.
public struct SideQuestion: Codable, Sendable, Hashable, Identifiable {
    public enum State: String, Codable, Sendable {
        case asking, answered, failed
    }

    public var id: UUID
    public var question: String
    /// What has come back so far, as Markdown.
    public var answer: String
    public var state: State
    /// Why it failed, for `.failed`.
    public var problem: String?

    public init(id: UUID = UUID(), question: String, answer: String = "", state: State = .asking, problem: String? = nil) {
        self.id = id
        self.question = question
        self.answer = answer
        self.state = state
        self.problem = problem
    }

    // Lenient, so a phone and a Mac a version apart still understand each other.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        question = try c.decodeIfPresent(String.self, forKey: .question) ?? ""
        answer = try c.decodeIfPresent(String.self, forKey: .answer) ?? ""
        state = (try? c.decodeIfPresent(State.self, forKey: .state)) ?? .answered
        problem = try c.decodeIfPresent(String.self, forKey: .problem)
    }

    /// The question in a message like "/btw what does this do?", or nil
    /// when the message isn't one. An empty string for "/btw" alone.
    public static func question(in message: String) -> String? {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.lowercased().hasPrefix("/btw") else { return nil }
        let rest = text.dropFirst("/btw".count)
        // "/btwx" is some other command.
        if let next = rest.first, !next.isWhitespace { return nil }
        return rest.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What's sent to Claude: the question, framed the way Claude Code
    /// frames its own side questions, so Claude answers from what it knows
    /// rather than going off to read files or run commands.
    ///
    /// `running` is what the main conversation is doing right now, like
    /// "ping -c 40 127.0.0.1", when it's busy. The copy Claude answers
    /// from marks a tool call that hasn't finished as interrupted, so
    /// without this Claude says the work stopped when it hasn't.
    public static func prompt(for question: String, running: String? = nil) -> String {
        let now: String
        if let running = running?.trimmingCharacters(in: .whitespacesAndNewlines), !running.isEmpty {
            now = "The main conversation is still working right now, on this step: \(running). " +
                "Any tool call above marked as interrupted or without a result is still running, not stopped."
        } else {
            now = "The main conversation may be in the middle of its work: a tool call above with no result yet " +
                "is still running, not interrupted."
        }
        return """
        <system-reminder>This is a side question from the user, asked while the main conversation carries on. \
        \(now) Answer directly and concisely from what you already know in this conversation. \
        Don't use any tools, don't start or continue any task, and don't mention this reminder.</system-reminder>
        \(question)
        """
    }
}

/// Reads `claude -p --output-format stream-json --include-partial-messages`
/// a line at a time.
public enum SideQuestionStream {
    public enum Event: Equatable {
        /// More of the answer.
        case text(String)
        /// The run is over: the whole answer, or why it failed.
        case finished(text: String, isError: Bool)
        /// Claude has started to call a tool. A side question never gets
        /// to: the run is stopped here, before the call can happen.
        case toolCall
    }

    /// What one line of output means, or nil for the lines that don't
    /// change the answer.
    public static func event(in line: String) -> Event? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch type {
        case "stream_event":
            guard let event = object["event"] as? [String: Any] else { return nil }
            // The call's first sign, ahead of what it's called with.
            if event["type"] as? String == "content_block_start",
               let block = event["content_block"] as? [String: Any], isToolCall(block) {
                return .toolCall
            }
            guard event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String, !text.isEmpty else { return nil }
            return .text(text)
        case "assistant":
            // The whole reply, in case the call's start never came by itself.
            guard let message = object["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]],
                  content.contains(where: isToolCall) else { return nil }
            return .toolCall
        case "result":
            let isError = object["is_error"] as? Bool ?? (object["subtype"] as? String != "success")
            return .finished(text: (object["result"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                             isError: isError)
        default:
            return nil
        }
    }

    /// `tool_use`, and the kinds named after it (`server_tool_use`).
    private static func isToolCall(_ block: [String: Any]) -> Bool {
        (block["type"] as? String)?.hasSuffix("tool_use") == true
    }

    /// Whether this line is the start of a tool call. Cheap for the lines
    /// that aren't, which is nearly all of them.
    public static func startsToolCall(_ line: String) -> Bool {
        line.contains("tool_use") && event(in: line) == .toolCall
    }
}

/// The folder a Claude session ran in, from its transcript.
public enum TranscriptFolder {
    /// The `cwd` of the first entry that has one, looking only at the
    /// start of the file.
    public static func read(transcript path: String, bytes: Int = 256 * 1024) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: bytes) else { return nil }
        return find(in: String(decoding: data, as: UTF8.self))
    }

    static func find(in text: String) -> String? {
        for line in text.split(separator: "\n") where line.contains("\"cwd\"") {
            if let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
               let cwd = object["cwd"] as? String, !cwd.isEmpty {
                return cwd
            }
        }
        return nil
    }
}
