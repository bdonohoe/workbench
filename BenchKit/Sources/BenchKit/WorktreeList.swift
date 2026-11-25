import Foundation

/// Reads `git worktree list --porcelain`, and decides which of a repo's
/// worktrees belong in the sidebar.
public enum WorktreeList {
    public struct Entry: Equatable, Sendable {
        public var path: String
        /// The checked-out branch, or nil when HEAD is detached.
        public var branch: String?
        public var isBare = false
        /// Git knows the folder is gone and would clean this up on a prune.
        public var isPrunable = false

        public init(path: String, branch: String? = nil, isBare: Bool = false, isPrunable: Bool = false) {
            self.path = path
            self.branch = branch
            self.isBare = isBare
            self.isPrunable = isPrunable
        }
    }

    /// Git lists the repo's main worktree first.
    public static func parse(_ porcelain: String) -> [Entry] {
        var entries: [Entry] = []
        for line in porcelain.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("worktree ") {
                entries.append(Entry(path: String(line.dropFirst("worktree ".count))))
            } else if entries.isEmpty {
                continue
            } else if line.hasPrefix("branch refs/heads/") {
                entries[entries.count - 1].branch = String(line.dropFirst("branch refs/heads/".count))
            } else if line == "bare" {
                entries[entries.count - 1].isBare = true
            } else if line == "prunable" || line.hasPrefix("prunable ") {
                entries[entries.count - 1].isPrunable = true
            }
        }
        return entries
    }

    /// A path with symlinks resolved. Git reports resolved paths and a
    /// project's saved path may not be, so compare these.
    public static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// True if `repo` is the main worktree of this list. A project that's
    /// itself a linked worktree, or a folder inside a repo, isn't the
    /// parent of the others.
    public static func isMainWorktree(_ repo: String, of entries: [Entry]) -> Bool {
        guard let main = entries.first, !main.isBare else { return false }
        return resolved(main.path) == resolved(repo)
    }

    /// The worktrees to add under `repo`: the linked ones that aren't
    /// already known or hidden, and that are still there. Includes ones
    /// Claude Code made, since you may have started those in another
    /// terminal and want them here.
    public static func importable(_ entries: [Entry], known: Set<String>, hidden: Set<String>) -> [Entry] {
        let known = Set(known.map(resolved))
        let hidden = Set(hidden.map(resolved))
        return entries.dropFirst().filter { entry in
            let path = resolved(entry.path)
            return !entry.isBare && !entry.isPrunable
                && !known.contains(path) && !hidden.contains(path)
        }
    }
}
