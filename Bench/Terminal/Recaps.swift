import BenchKit
import Foundation

/// Short recaps of what Claude did in a turn, written by a small Claude
/// model in the background: "Added project renaming and opened PR #114.
/// The build passes."
///
/// A turn that used tools gets one when it finishes. A plain reply keeps
/// the start of Claude's own words, which already say it. Recaps are kept
/// on disk, so a relaunch doesn't ask again.
final class Recaps {
    static let shared = Recaps()
    static let enabledKey = "recaps.enabled"

    /// Off in Settings > General, or when Claude Code isn't installed.
    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    /// Called when a recap arrives, so the watcher can show it.
    var onRecap: (() -> Void)?

    /// Recaps by "transcript@stop time".
    private var done: [String: String] = [:]
    private var order: [String] = []
    private var running: [String: Task<String?, Never>] = [:]
    private static let file = BenchPaths.support.appendingPathComponent("recaps.json")
    private static let keep = 300

    private init() {
        if let data = try? Data(contentsOf: Self.file),
           let saved = try? JSONDecoder().decode([Saved].self, from: data) {
            for item in saved {
                done[item.key] = item.text
                order.append(item.key)
            }
        }
    }

    private struct Saved: Codable {
        var key: String
        var text: String
    }

    static func key(transcript: String, stoppedAt: Date?) -> String {
        // Whole milliseconds: file dates don't always come back with the
        // same precision.
        "\(transcript)@\(Int(((stoppedAt?.timeIntervalSince1970 ?? 0) * 1000).rounded()))"
    }

    /// The recap for a finished turn, if it's ready. Starts writing one for
    /// a recent turn that doesn't have one yet.
    func recap(transcript: String, stoppedAt: Date?) -> String? {
        let key = Self.key(transcript: transcript, stoppedAt: stoppedAt)
        if let text = done[key] { return text.isEmpty ? nil : text }
        // Turns from before a relaunch keep their first lines.
        guard isEnabled, let stoppedAt, Date().timeIntervalSince(stoppedAt) < 10 * 60 else { return nil }
        start(key: key, transcript: transcript)
        return nil
    }

    /// Waits a little for a recap that's being written, for a notification
    /// that would rather say what happened than how Claude's reply began.
    func waitForRecap(transcript: String, stoppedAt: Date?, timeout: TimeInterval = 12) async -> String? {
        let key = Self.key(transcript: transcript, stoppedAt: stoppedAt)
        if let text = done[key] { return text.isEmpty ? nil : text }
        _ = recap(transcript: transcript, stoppedAt: stoppedAt)
        guard running[key] != nil else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let text = done[key] { return text.isEmpty ? nil : text }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }

    private func start(key: String, transcript: String) {
        guard running[key] == nil else { return }
        // On the account the session ran on, not whichever is the main one.
        let profile = ClaudeAccounts.shared.profile(forTranscript: transcript)
        let task = Task.detached(priority: .utility) { () -> String? in
            guard let turn = Self.turn(transcript: transcript), turn.usedTools else { return nil }
            return Self.write(turn.text, profile: profile)
        }
        running[key] = task
        Task {
            let text = await task.value
            running[key] = nil
            remember(key, text ?? "")
            if text != nil { onRecap?() }
        }
    }

    private func remember(_ key: String, _ text: String) {
        done[key] = text
        order.append(key)
        if order.count > Self.keep {
            for old in order.prefix(order.count - Self.keep) { done[old] = nil }
            order.removeFirst(order.count - Self.keep)
        }
        let saved = order.compactMap { key in done[key].map { Saved(key: key, text: $0) } }
        if let data = try? JSONEncoder().encode(saved) {
            try? data.write(to: Self.file, options: .atomic)
        }
    }

    // MARK: Reading the turn

    typealias Turn = RecapTurn

    /// The latest turn, condensed: what you asked, each step the agent
    /// took in a few words, and what it said along the way and at the end.
    nonisolated static func turn(transcript path: String) -> Turn? {
        Agents.transcripts(for: path).recapTurn(in: path)
    }

    /// The same, read from one of Claude Code's transcripts.
    nonisolated static func claudeTurn(transcript path: String) -> Turn? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        // A long turn can be big, but its steps fit in the last few MB.
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: end > 4_000_000 ? end - 4_000_000 : 0)
        guard let data = try? handle.readToEnd() else { return nil }

        var prompt: String?
        var steps: [String] = []
        var said: [String] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let message = entry["message"] as? [String: Any] else { continue }
            switch entry["type"] as? String {
            case "user":
                // A prompt you typed starts a new turn. Tool results and
                // Claude Code's own notes don't.
                guard entry["isMeta"] as? Bool != true, let text = typedText(message["content"]) else { continue }
                prompt = text
                steps = []
                said = []
            case "assistant":
                for block in message["content"] as? [[String: Any]] ?? [] {
                    switch block["type"] as? String {
                    case "text":
                        let text = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty { said.append(text) }
                    case "tool_use":
                        let tool = block["name"] as? String ?? ""
                        steps.append(ToolWording.describe(tool: tool, input: block["input"] as? [String: Any] ?? [:]))
                    default:
                        break
                    }
                }
            default:
                break
            }
        }
        guard let prompt, !said.isEmpty || !steps.isEmpty else { return nil }

        var text = "What the user asked:\n" + clip(prompt, 1500) + "\n\n"
        if !steps.isEmpty {
            // Long runs of steps keep their start and end.
            let shown = steps.count > 80 ? Array(steps.prefix(30)) + ["(\(steps.count - 70) more steps)"] + Array(steps.suffix(40)) : steps
            text += "Steps Claude took:\n" + shown.map { "- " + clip($0, 160) }.joined(separator: "\n") + "\n\n"
        }
        if said.count > 1 {
            text += "What Claude said along the way:\n" + said.dropLast().suffix(6).map { "- " + clip($0, 300) }.joined(separator: "\n") + "\n\n"
        }
        if let last = said.last { text += "Claude's final reply:\n" + clip(last, 2500) }
        return Turn(text: text, usedTools: !steps.isEmpty)
    }

    /// The words of a prompt you typed, or nil for a tool result.
    nonisolated private static func typedText(_ content: Any?) -> String? {
        if let text = content as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Claude Code's command echoes and caveats aren't prompts.
            guard !trimmed.isEmpty, !trimmed.hasPrefix("<"), !TranscriptParser.isFromTeammate(trimmed) else { return nil }
            return trimmed
        }
        guard let blocks = content as? [[String: Any]],
              !blocks.contains(where: { $0["type"] as? String == "tool_result" }) else { return nil }
        let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || text.hasPrefix("<") || TranscriptParser.isFromTeammate(text) ? nil : text
    }

    nonisolated private static func clip(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    // MARK: Asking Claude

    nonisolated static let instructions = """
        You write recaps of a Claude Code turn for a developer glancing at a notification. \
        From what they asked and what Claude did, write one short, plain sentence, two at \
        most, under 150 characters in all: what got done, and anything left for them, like \
        a failing test or a question Claude asked. Start with the verb, in the past tense, \
        like "Fixed the login crash and opened PR #12." Never start with "I" or "Claude". \
        Name the feature, file, or pull request when it helps. No preamble, markdown, \
        quotes, or em dashes.
        """

    /// Asks a small Claude model for the recap.
    nonisolated static func write(_ turn: String, profile: ClaudeProfile) -> String? {
        AgentRunner.ask(turn, instructions: instructions, timeout: 60, profile: profile).flatMap(tidy)
    }

    /// One line, no wrapping quotes or dashes, and short enough for a banner.
    nonisolated static func tidy(_ raw: String) -> String? {
        var text = raw.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
            .replacingOccurrences(of: " — ", with: ", ")
            .replacingOccurrences(of: "—", with: ", ")
        if text.count > 280 { text = String(text.prefix(279)) + "…" }
        return text.isEmpty ? nil : text
    }
}
