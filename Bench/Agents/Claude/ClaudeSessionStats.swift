import BenchKit
import Foundation

/// Claude Code's side of `SessionStats`: which lines of its transcript
/// carry token counts, checklist changes, model and effort switches.
nonisolated enum ClaudeSessionStats {
    private static let markers = [#""usage""#, #""TaskCreate""#, #""TaskUpdate""#, #""TodoWrite""#, #""toolUseResult""#, "Set model to", "Set effort level to", "[Request interrupted"].map { Data($0.utf8) }
    private static let iso = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// When a user line is Claude Code's note that you interrupted it.
    private static func interruption(_ entry: [String: Any]) -> Date? {
        guard entry["type"] as? String == "user", entry["isSidechain"] as? Bool != true,
              let content = (entry["message"] as? [String: Any])?["content"] as? [[String: Any]],
              content.contains(where: { ($0["text"] as? String)?.hasPrefix("[Request interrupted") == true }),
              let stamp = entry["timestamp"] as? String else { return nil }
        return try? iso.parse(stamp)
    }

    static func read(lines chunk: Data, into state: inout SessionStats) {
        for line in chunk.split(separator: UInt8(ascii: "\n")) where markers.contains(where: { line.range(of: $0) != nil }) {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            state.checklist.apply(entry)
            state.trail.apply(entry)
            let edited = CrossProjectEdits.editedFiles(in: entry)
            if !edited.isEmpty {
                let at = (entry["timestamp"] as? String).flatMap { try? iso.parse($0) } ?? Date()
                for file in edited { state.editedFiles[file] = at }
            }
            if let at = interruption(entry) { state.interruptedAt = at; continue }
            if let name = switchedModel(entry) {
                state.usage.switchedTo = name
                // Claude Code keeps an effort level for each model, so a
                // new model brings its own.
                state.effort = nil
                state.effortAt = nil
                continue
            }
            if let level = setEffort(entry) {
                state.effort = level
                state.effortAt = (entry["timestamp"] as? String).flatMap { try? iso.parse($0) } ?? Date()
                continue
            }
            guard entry["type"] as? String == "assistant",
                  let message = entry["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  message["model"] as? String != "<synthetic>" else { continue }  // Claude Code's own error notes
            let id = message["id"] as? String ?? UUID().uuidString
            guard !state.seen.contains(id) else { continue }
            state.seen.insert(id)
            let count = { (key: String) in usage[key] as? Int ?? 0 }
            let output = count("output_tokens")
            state.usage.contextTokens = count("input_tokens") + count("cache_creation_input_tokens")
                + count("cache_read_input_tokens") + output
            state.usage.peakTokens = max(state.usage.peakTokens, state.usage.contextTokens)
            state.usage.outputTokens += output
            if let model = message["model"] as? String, entry["isSidechain"] as? Bool != true {
                state.usage.model = model
                state.usage.switchedTo = nil
            }
        }
    }

    /// The level picked with /effort, from Claude Code's note about it:
    /// "Set effort level to medium (saved as your default for new sessions): …".
    static func setEffort(_ entry: [String: Any]) -> String? {
        guard entry["type"] as? String == "user",
              let content = (entry["message"] as? [String: Any])?["content"] as? String,
              let start = content.range(of: "<local-command-stdout>Set effort level to ") else { return nil }
        let rest = content[start.upperBound...].replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        let level = rest.prefix { $0.isLetter }.lowercased()
        return level.isEmpty ? nil : level
    }

    /// The model picked with /model, from Claude Code's note about it:
    /// "Set model to `Opus 5.5` and saved as your default for new sessions".
    private static func switchedModel(_ entry: [String: Any]) -> String? {
        guard entry["type"] as? String == "user",
              let content = (entry["message"] as? [String: Any])?["content"] as? String,
              let start = content.range(of: "<local-command-stdout>Set model to ") else { return nil }
        var rest = String(content[start.upperBound...])
        if let end = rest.range(of: "</local-command-stdout>") { rest = String(rest[..<end.lowerBound]) }
        rest = rest.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        let parts = rest.split(separator: "`", omittingEmptySubsequences: false)
        let name = parts.count >= 3 ? String(parts[1])
            : String(rest.components(separatedBy: " and ").first ?? rest)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
