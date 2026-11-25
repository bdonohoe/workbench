import Foundation

/// How a file changed, from git's status letters.
public enum ChangeKind: String, Codable, Sendable {
    case modified = "M"
    case added = "A"
    case deleted = "D"
    case renamed = "R"
    case copied = "C"
    case untracked = "?"
    case conflicted = "U"
    case typeChanged = "T"

    public init(letter: Character) {
        self = ChangeKind(rawValue: String(letter)) ?? .modified
    }
}

/// Which comparison a file change belongs to.
public enum ChangeSection: String, Codable, Sendable, Hashable {
    case staged
    case unstaged
    case againstBase
}

public struct FileChange: Identifiable, Hashable, Codable, Sendable {
    public var path: String
    public var oldPath: String?
    public var kind: ChangeKind
    public var additions: Int
    public var deletions: Int
    public var isBinary = false
    public var section: ChangeSection

    public init(path: String, oldPath: String? = nil, kind: ChangeKind, additions: Int, deletions: Int,
                isBinary: Bool = false, section: ChangeSection) {
        self.path = path
        self.oldPath = oldPath
        self.kind = kind
        self.additions = additions
        self.deletions = deletions
        self.isBinary = isBinary
        self.section = section
    }

    public var id: String { "\(section.rawValue):\(path)" }
    public var fileName: String { (path as NSString).lastPathComponent }
    /// Image formats the diff view shows as pictures instead of text.
    public var isImage: Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "ico", "icns"].contains(ext)
    }
    public var directory: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "" : dir
    }
}

public struct Commit: Identifiable, Hashable, Codable, Sendable {
    public var hash: String
    public var shortHash: String
    public var subject: String
    public var body: String
    public var author: String
    public var date: Date
    public var additions = 0
    public var deletions = 0
    public var id: String { hash }

    public init(hash: String, shortHash: String, subject: String, body: String, author: String, date: Date,
                additions: Int = 0, deletions: Int = 0) {
        self.hash = hash
        self.shortHash = shortHash
        self.subject = subject
        self.body = body
        self.author = author
        self.date = date
        self.additions = additions
        self.deletions = deletions
    }
}

/// A project's git state as the Changes panel shows it.
public struct ChangesSnapshot: Codable, Sendable, Hashable {
    public var branch: String?
    /// The ref being compared against, like "origin/main".
    public var baseRef: String?
    public var staged: [FileChange]
    public var unstaged: [FileChange]
    public var againstBase: [FileChange]
    /// Commits on this branch that aren't on the base, newest first.
    public var commits: [Commit]
    public var isRepository: Bool
    public var error: String?

    // The rest is for the Changes panel's header. Older Macs leave it out.

    /// How this branch relates to the base: commits only here, commits only there.
    public var aheadOfBase: Int?
    public var behindBase: Int?
    /// When this branch split from the base (the merge-base commit's date).
    public var forkedAt: Date?
    /// The tracking branch, like "origin/feat/x", if there is one.
    public var upstream: String?
    public var unpushed: Int?
    public var unpulled: Int?
    /// When anything was last fetched into this repository.
    public var lastFetch: Date?
    /// Branches to compare against, most recently committed first.
    public var branches: [String]?
    /// The base someone picked for this project, or nil for the default branch.
    public var chosenBase: String?

    public init(branch: String? = nil, baseRef: String? = nil, staged: [FileChange] = [], unstaged: [FileChange] = [],
                againstBase: [FileChange] = [], commits: [Commit] = [], isRepository: Bool = true, error: String? = nil,
                aheadOfBase: Int? = nil, behindBase: Int? = nil, forkedAt: Date? = nil, upstream: String? = nil,
                unpushed: Int? = nil, unpulled: Int? = nil, lastFetch: Date? = nil,
                branches: [String]? = nil, chosenBase: String? = nil) {
        self.branch = branch
        self.baseRef = baseRef
        self.staged = staged
        self.unstaged = unstaged
        self.againstBase = againstBase
        self.commits = commits
        self.isRepository = isRepository
        self.error = error
        self.aheadOfBase = aheadOfBase
        self.behindBase = behindBase
        self.forkedAt = forkedAt
        self.upstream = upstream
        self.unpushed = unpushed
        self.unpulled = unpulled
        self.lastFetch = lastFetch
        self.branches = branches
        self.chosenBase = chosenBase
    }

    public var fileCount: Int { staged.count + unstaged.count + againstBase.count }

    /// The upstream's remote name: "origin" for "origin/feat/x".
    public var remoteName: String? { upstream?.split(separator: "/").first.map(String.init) }
}
