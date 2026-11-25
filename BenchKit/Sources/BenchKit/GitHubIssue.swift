import Foundation

/// An open issue on a project's GitHub repo, as `gh issue list` reports it.
/// An agent can start from one: the issue supplies its prompt and branch.
public struct GitHubIssue: Equatable, Identifiable, Sendable {
    public var number: Int
    public var title: String
    public var url: URL
    public var labels: [String]
    public var updated: Date?

    public var id: Int { number }

    public init(number: Int, title: String, url: URL, labels: [String] = [], updated: Date? = nil) {
        self.number = number
        self.title = title
        self.url = url
        self.labels = labels
        self.updated = updated
    }

    /// What `gh issue list` and `gh issue view` are asked for.
    public static let jsonFields = "number,title,url,labels,updatedAt"

    /// The answer to `gh issue list --json`, in the order GitHub gave.
    public static func parseList(_ data: Data) -> [GitHubIssue] {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list.compactMap(parse)
    }

    /// The answer to `gh issue view --json`.
    public static func parseOne(_ data: Data) -> GitHubIssue? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap(parse)
    }

    private static func parse(_ json: [String: Any]) -> GitHubIssue? {
        guard let number = json["number"] as? Int, let title = json["title"] as? String,
              let url = (json["url"] as? String).flatMap(URL.init(string:)) else { return nil }
        let labels = (json["labels"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        let updated = (json["updatedAt"] as? String).flatMap { try? Date($0, strategy: .iso8601) }
        return GitHubIssue(number: number, title: title, url: url, labels: labels, updated: updated)
    }

    /// The issue number in "412", "#412" or an issue's web address.
    public static func number(from text: String) -> Int? {
        var text = text.trimmingCharacters(in: .whitespaces)
        if let url = URL(string: text), url.scheme != nil, url.pathComponents.dropLast().last == "issues" {
            text = url.lastPathComponent
        }
        if text.hasPrefix("#") { text.removeFirst() }
        guard !text.isEmpty, text.allSatisfy(\.isNumber), let number = Int(text), number > 0 else { return nil }
        return number
    }

    /// Labelled as a bug, or titled like one.
    public var isBug: Bool {
        labels.contains { $0.localizedCaseInsensitiveContains("bug") } || BranchNames.suggest(from: title).hasPrefix("fix/")
    }

    /// The first prompt for an agent that starts from this issue. It
    /// points at the issue rather than quoting it, so Claude reads the
    /// comments too and the prompt stays short enough to edit.
    public var prompt: String {
        """
        \(isBug ? "Fix" : "Work on") issue #\(number): \(title)
        \(url.absoluteString)

        Read the issue and its comments with `gh issue view \(number) --comments` before you start.
        """
    }

    /// A branch named for the issue, like "fix/412-sidebar-flickers-wake".
    public var branch: String {
        let suggested = BranchNames.suggest(from: title)
        let slug = suggested.split(separator: "/", maxSplits: 1).last.map(String.init) ?? "agent"
        return (isBug ? "fix/" : "feat/") + "\(number)" + (slug == "agent" ? "" : "-" + slug)
    }

    /// Whether a search matches: by number ("412" or "#412"), title or label.
    public func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        if query.isEmpty { return true }
        let digits = query.hasPrefix("#") ? String(query.dropFirst()) : query
        if !digits.isEmpty, digits.allSatisfy(\.isNumber), "\(number)".hasPrefix(digits) { return true }
        return title.localizedCaseInsensitiveContains(query) || labels.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}
