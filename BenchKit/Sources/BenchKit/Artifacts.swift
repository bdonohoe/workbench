import Foundation

/// A web page Claude published to claude.ai, like a dashboard, a mockup,
/// or a write-up.
public struct ArtifactLink: Codable, Sendable, Hashable, Identifiable {
    public var id: String { url }
    public var url: String
    public var title: String
    /// When it was last published.
    public var updated: Date
    /// 2 and up once it's been republished.
    public var version: Int?
    /// A word for its icon, like "chart" or "map", when Claude gave one.
    public var icon: String?
    /// The conversation that published it, and that conversation's title.
    public var sessionID: String?
    public var sessionTitle: String?

    public init(url: String, title: String, updated: Date, version: Int? = nil, icon: String? = nil,
                sessionID: String? = nil, sessionTitle: String? = nil) {
        self.url = url
        self.title = title
        self.updated = updated
        self.version = version
        self.icon = icon
        self.sessionID = sessionID
        self.sessionTitle = sessionTitle
    }

    /// An SF Symbol for its icon word.
    public var symbol: String { ArtifactPublish.symbol(for: icon) }
}

/// Recognizes Claude publishing an artifact: the built-in Artifact tool,
/// or the claude-artifacts MCP server's publish tools.
public enum ArtifactPublish {
    private static let mcpPublishTools: Set<String> = ["publish_files", "publish_version", "edit_version", "create_from_type"]

    /// True for a tool call that publishes a page (not one that reads,
    /// lists, deletes, or uploads an image to one).
    public static func isPublish(tool: String, input: [String: Any]) -> Bool {
        if tool == "Artifact" {
            let action = input["action"] as? String ?? "publish"
            return action == "publish" && input["asset"] as? Bool != true
        }
        guard tool.hasPrefix("mcp__"), tool.contains("artifacts__"),
              let name = tool.components(separatedBy: "__").last else { return false }
        return mcpPublishTools.contains(name) && input["asset"] as? Bool != true
    }

    /// True for a step the chat view shows as a publish, by its tool name.
    public static func isPublish(tool: String?) -> Bool {
        guard let tool else { return false }
        if tool == "Artifact" { return true }
        return tool.hasPrefix("mcp__") && tool.contains("artifacts__")
            && mcpPublishTools.contains(tool.components(separatedBy: "__").last ?? "")
    }

    /// The best name for a publish from what Claude passed the tool: its
    /// page's own `<title>`, the title it gave, or the file's name.
    public static func title(tool: String, input: [String: Any]) -> String? {
        titleGuess(tool: tool, input: input)?.title
    }

    /// The same, with how sure it is, so the best name across a page's
    /// publishes wins: 3 for the name Claude gave it, 2 for the page's own
    /// `<title>`, 1 for its file name, 0 for its description.
    public static func titleGuess(tool: String, input: [String: Any]) -> (title: String, rank: Int)? {
        if let title = input["title"] as? String, !title.isEmpty { return (title, 3) }
        let path = input["file_path"] as? String
            ?? (input["files"] as? [[String: Any]])?.first(where: { $0["as"] as? String == "index.html" })?["path"] as? String
        if let path, let title = pageTitle(atPath: path) { return (title, 2) }
        if let path, path.hasSuffix(".html"), let name = name(fromPath: path) { return (name, 1) }
        if let description = input["description"] as? String, !description.isEmpty {
            return (description.count > 60 ? String(description.prefix(59)) + "…" : description, 0)
        }
        return nil
    }

    /// What a publish's result says: its link, and its title, version,
    /// icon and time when the result has them. The MCP tools answer with
    /// JSON; the built-in tool with a sentence like "Published page.html at
    /// https://claude.ai/artifact/… (Version 2, …) Icon: "grid"". When the
    /// result doesn't say when, `updated` is `.distantPast`, for the caller
    /// to fill in from the transcript.
    public static func link(fromResult text: String) -> ArtifactLink? {
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Some answers put a sentence right after the JSON, on the same line.
            guard trimmed.hasPrefix("{"), trimmed.contains("claude.ai/"),
                  let json = leadingObject(in: trimmed),
                  let url = json["url"] as? String, isArtifactURL(url) else { continue }
            return ArtifactLink(url: url, title: json["title"] as? String ?? "",
                                updated: (json["updated_at"] as? String).flatMap(date) ?? .distantPast,
                                version: (json["seq"] as? NSNumber)?.intValue, icon: json["icon"] as? String)
        }
        guard text.hasPrefix("Published") || text.contains(" at https://claude.ai/"),
              let url = firstMatch(#"https://claude\.ai/(?:code/)?artifact/[A-Za-z0-9_-]+"#, in: text) else { return nil }
        // "(Version 2, version id 1793…)": the small number, not the id.
        let version = firstMatch(#"\(Version (\d{1,5})[,)]"#, in: text, group: 1, ignoringCase: false).flatMap(Int.init)
        let icon = firstMatch(#"Icon: "([^"]+)""#, in: text, group: 1)
        return ArtifactLink(url: url, title: "", updated: .distantPast, version: version, icon: icon)
    }

    /// The JSON object a line starts with, ignoring anything after it.
    static func leadingObject(in line: String) -> [String: Any]? {
        if let whole = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] { return whole }
        var depth = 0
        var inString = false
        var escaped = false
        for (offset, byte) in line.utf8.enumerated() {
            if inString {
                if escaped { escaped = false } else if byte == UInt8(ascii: "\\") { escaped = true } else if byte == UInt8(ascii: "\"") { inString = false }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "{"): depth += 1
            case UInt8(ascii: "}"):
                depth -= 1
                if depth == 0 {
                    let object = Data(line.utf8.prefix(offset + 1))
                    return try? JSONSerialization.jsonObject(with: object) as? [String: Any]
                }
            default: break
            }
        }
        return nil
    }

    public static func isArtifactURL(_ url: String) -> Bool {
        url.hasPrefix("https://claude.ai/artifact/") || url.hasPrefix("https://claude.ai/code/artifact/")
    }

    /// The `<title>` of a page on disk, if it's still there.
    public static func pageTitle(atPath path: String) -> String? {
        #if os(macOS)
        guard path.hasSuffix(".html") || path.hasSuffix(".htm"),
              let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 32 * 1024),
              let head = String(data: data, encoding: .utf8),
              let title = firstMatch(#"<title[^>]*>([^<]+)</title>"#, in: head, group: 1) else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
        #else
        return nil
        #endif
    }

    /// "home-rethink.html" as "Home rethink". Nil for a bare "index.html".
    static func name(fromPath path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        var base = url.deletingPathExtension().lastPathComponent
        if base == "index" { base = url.deletingLastPathComponent().lastPathComponent }
        let words = base.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty, words != "scratchpad" else { return nil }
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// An SF Symbol for the one-word icons Claude gives pages.
    public static func symbol(for icon: String?) -> String {
        switch icon?.lowercased() ?? "" {
        case "chart", "chartbar", "graph", "dashboard", "barchart": "chart.bar.xaxis"
        case "gauge", "meter", "speedometer": "gauge.with.dots.needle.33percent"
        case "calendar", "schedule": "calendar"
        case "map", "location": "map"
        case "code", "commandline", "terminal": "chevron.left.forwardslash.chevron.right"
        case "music", "audio": "music.note"
        case "grid", "layout", "squares": "square.grid.2x2"
        case "video", "play", "playcircle", "film": "play.circle"
        case "link", "share": "link"
        case "list", "checklist", "todo", "tasks": "checklist"
        case "game", "gamecontroller": "gamecontroller"
        case "book", "docs", "guide": "book"
        case "phone", "iphone", "mobile": "iphone"
        case "design", "palette", "paint": "paintpalette"
        case "chat", "message": "bubble.left.and.bubble.right"
        case "table", "spreadsheet": "tablecells"
        case "image", "photo", "picture": "photo"
        case "star", "sparkle", "sparkles": "sparkles"
        default: "doc.richtext"
        }
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private static func firstMatch(_ pattern: String, in text: String, group: Int = 0, ignoringCase: Bool = true) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: ignoringCase ? [.caseInsensitive] : []),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: group), in: text) else { return nil }
        return String(text[range])
    }
}
