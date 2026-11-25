import Foundation

/// One file in a review: its place and what happened to it.
public struct ReviewFile: Identifiable, Equatable, Hashable, Codable, Sendable {
    public var path: String
    /// "A", "M", "D" or "R".
    public var status: String
    public var additions = 0
    public var deletions = 0
    /// Where its header sits in the review's lines.
    public var headerLine = 0
    public var id: String { path }

    public init(path: String, status: String) {
        self.path = path
        self.status = status
    }

    public var fileName: String { (path as NSString).lastPathComponent }
    public var directory: String { (path as NSString).deletingLastPathComponent }
}

/// A diff of many files read as one: each file's lines after a header row
/// with its path and counts, so they scroll and select as one text.
public struct ReviewDiff: Equatable, Codable, Sendable {
    public var files: [ReviewFile] = []
    public var lines: [DiffLine] = []

    public init() {}

    public init(parsing text: String) {
        for chunk in Self.chunks(text) {
            let parsed = DiffParser.parse(chunk.text)
            var file = ReviewFile(path: chunk.path, status: chunk.status)
            file.additions = parsed.count { $0.kind == .added }
            file.deletions = parsed.count { $0.kind == .removed }
            file.headerLine = lines.count
            let id = lines.count
            lines.append(DiffLine(id: id, kind: .hunk, text: Self.headerText(file), oldNumber: nil, newNumber: nil))
            // Ids run on across files, so each line's is unique in the review.
            for line in parsed {
                lines.append(DiffLine(id: lines.count, kind: line.kind, text: line.text, oldNumber: line.oldNumber,
                                      newNumber: line.newNumber, segments: line.segments))
            }
            files.append(file)
        }
    }

    /// The lines of the file at `index` in `files`, without its header row.
    public func lineRange(ofFileAt index: Int) -> Range<Int> {
        let start = files[index].headerLine + 1
        let end = index + 1 < files.count ? files[index + 1].headerLine : lines.count
        return start..<max(start, end)
    }

    /// "replay.ts  src/sim  +27 −16": the counts are colored by the text view.
    public static func headerText(_ file: ReviewFile) -> String {
        var text = file.path
        if file.additions > 0 || file.deletions > 0 { text += "  +\(file.additions) −\(file.deletions)" }
        return text
    }

    /// Splits `git diff` output at each "diff --git" line, with the path
    /// and status read from the lines after it.
    private static func chunks(_ text: String) -> [(path: String, status: String, text: String)] {
        var result: [(path: String, status: String, text: String)] = []
        var current: [Substring] = []
        func finish() {
            guard let first = current.first else { return }
            var path = first.range(of: " b/").map { String(first[$0.upperBound...]) } ?? String(first)
            var status = "M"
            for line in current.prefix(8) {
                if line.hasPrefix("new file") { status = "A" }
                if line.hasPrefix("deleted file") { status = "D" }
                if line.hasPrefix("rename to ") { status = "R"; path = String(line.dropFirst("rename to ".count)) }
                if line.hasPrefix("+++ b/") { path = String(line.dropFirst(6)) }
            }
            result.append((path, status, current.joined(separator: "\n")))
            current = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") { finish() }
            current.append(line)
        }
        finish()
        return result
    }
}

/// One commit on one page, for a client with the codeReview feature.
public struct CommitReview: Codable, Sendable, Equatable {
    public var commit: Commit
    public var diff: ReviewDiff
    /// The commit was too big to send whole, so `diff` stops early.
    public var truncated: Bool

    public init(commit: Commit, diff: ReviewDiff, truncated: Bool) {
        self.commit = commit
        self.diff = diff
        self.truncated = truncated
    }
}
