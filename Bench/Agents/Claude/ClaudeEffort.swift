import Foundation

/// The effort level Claude Code saved for a model in its settings, which
/// is what a session uses until you change it with /effort.
nonisolated enum ClaudeEffort {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: (date: Date, settings: [String: Any])?

    /// Like "high", for a model named like "Opus 5.5". nil when nothing is
    /// saved, so Claude Code uses the model's own default.
    static func saved(forModel name: String?) -> String? {
        let settings = read()
        if let id = name.map(modelID),
           let perModel = (settings["modelSettings"] as? [String: Any])?[id] as? [String: Any],
           let level = perModel["effortLevel"] as? String {
            return level
        }
        return settings["effortLevel"] as? String
    }

    /// "claude-opus-5-5" from "Opus 5.5".
    static func modelID(_ name: String) -> String {
        "claude-" + name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    /// Claude Code's settings, read again only when the file changes.
    private static func read() -> [String: Any] {
        let home = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        let file = home.appendingPathComponent("settings.json")
        let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        lock.lock()
        defer { lock.unlock() }
        if let cached, cached.date == date { return cached.settings }
        let settings = (try? Data(contentsOf: file))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        cached = (date, settings)
        return settings
    }
}
