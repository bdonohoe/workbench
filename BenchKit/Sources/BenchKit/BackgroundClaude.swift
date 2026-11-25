import Foundation

/// What `claude -p --output-format json` printed for a background call.
public struct BackgroundReply {
    public var text: String
    /// True when Claude Code reports the call failed, even with exit status 0.
    public var isError: Bool
    /// The model that answered, like "claude-haiku-5-5".
    public var model: String?
    /// Token counts, in the same shape as a transcript's `usage`.
    public var usage: [String: Any]?

    public init(text: String, isError: Bool, model: String?, usage: [String: Any]?) {
        self.text = text
        self.isError = isError
        self.model = model
        self.usage = usage
    }

    /// Nil when the output isn't Claude Code's JSON result.
    public static func parse(_ output: String) -> BackgroundReply? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
              object["type"] as? String == "result" else { return nil }
        let models = object["modelUsage"] as? [String: Any]
        return BackgroundReply(text: (object["result"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                               isError: object["is_error"] as? Bool ?? false,
                               model: models?.keys.sorted().first,
                               usage: object["usage"] as? [String: Any])
    }
}

/// Which Claude account a session belongs to, going by where its transcript is.
public enum TranscriptOwner {
    /// The index of the projects folder holding `transcript`, or nil if none
    /// does. The deepest wins, in case one account's folder is inside another's.
    public static func index(of transcript: String, amongProjectFolders folders: [String]) -> Int? {
        let path = URL(fileURLWithPath: transcript).standardizedFileURL.path
        var best: (index: Int, length: Int)?
        for (index, folder) in folders.enumerated() {
            let root = URL(fileURLWithPath: folder).standardizedFileURL.path + "/"
            if path.hasPrefix(root), root.count > (best?.length ?? 0) { best = (index, root.count) }
        }
        return best?.index
    }
}
