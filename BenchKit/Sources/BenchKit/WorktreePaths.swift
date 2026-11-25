import Foundation

/// Where Workbench puts the worktrees it makes. By default they sit in a
/// folder next to the repo: `~/Apps/Bench.worktrees/feat-menu-bar` for
/// `~/Apps/Bench`. In a folder you chose, each repo gets its own subfolder
/// so the same branch name in two repos doesn't collide:
/// `~/worktrees/Bench/feat-menu-bar`.
public enum WorktreePaths {
    private static let defaultSuffix = ".worktrees"

    public static func folder(forRepo repo: URL, branch: String, chosenFolder: URL?) -> URL {
        let slug = branch.replacingOccurrences(of: "/", with: "-")
        let shared = chosenFolder?.appendingPathComponent(repo.lastPathComponent, isDirectory: true)
            ?? repo.deletingLastPathComponent()
            .appendingPathComponent(repo.lastPathComponent + defaultSuffix, isDirectory: true)
        return shared.appendingPathComponent(slug, isDirectory: true)
    }

    /// True if a worktree's container is one Workbench made, so it can go
    /// once it's empty. Your chosen folder, and any other folder that
    /// happens to hold a worktree, stays.
    public static func canRemoveWhenEmpty(_ shared: URL, chosenFolder: URL?) -> Bool {
        let path = WorktreeList.resolved(shared.path)
        if let chosenFolder {
            let chosen = WorktreeList.resolved(chosenFolder.path)
            if path == chosen { return false }
            if WorktreeList.resolved(shared.deletingLastPathComponent().path) == chosen { return true }
        }
        return shared.lastPathComponent.hasSuffix(defaultSuffix)
    }

    /// The repo a worktree's folder belongs to, going by where it sits, or
    /// nil if it isn't in a place Workbench uses.
    public static func repoName(forFolder folder: String, chosenFolder: String?) -> String? {
        if let chosenFolder {
            let prefix = chosenFolder.hasSuffix("/") ? chosenFolder : chosenFolder + "/"
            if folder.hasPrefix(prefix), let name = folder.dropFirst(prefix.count).split(separator: "/").first {
                return String(name)
            }
        }
        let parts = folder.split(separator: "/")
        return parts.first { $0.hasSuffix(defaultSuffix) && $0.count > defaultSuffix.count }
            .map { String($0.dropLast(defaultSuffix.count)) }
    }
}
