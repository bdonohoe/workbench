import AppKit
import Foundation

/// Folders you've already used Claude Code in, read from its history in
/// ~/.claude/projects, newest first. Suggested when you first set up Bench.
struct ProjectSuggestion: Identifiable, Hashable, Sendable {
    var id: String { path }
    let path: String
    let lastUsed: Date
    /// The project's own icon file, if it has one Bench can find.
    let icon: URL?

    var name: String { URL(fileURLWithPath: path).lastPathComponent }

    /// "~/Apps/Bench".
    var shortPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

nonisolated enum ProjectSuggestions {
    /// Up to `limit` git repos, skipping ones in `excluding`, temporary
    /// folders, and agents' worktrees.
    static func load(excluding: Set<String>, limit: Int = 8) async -> [ProjectSuggestion] {
        await Task.detached(priority: .userInitiated) {
            find(excluding: excluding, limit: limit)
        }.value
    }

    private static func find(excluding: Set<String>, limit: Int) -> [ProjectSuggestion] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        // Wherever any agent has been used, by when it last was.
        var newest: [String: Date] = [:]
        for reader in Agents.allTranscripts {
            newest.merge(reader.recentFolders()) { max($0, $1) }
        }

        return newest
            .filter { path, _ in
                var isDir: ObjCBool = false
                let url = URL(fileURLWithPath: path)
                return !excluding.contains(path)
                    && path != home.path && path != "/"
                    && !url.deletingLastPathComponent().lastPathComponent.hasSuffix("-agents")
                    && !["/tmp/", "/private/tmp/", "/var/folders/", "/private/var/"].contains { path.hasPrefix($0) }
                    && fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
                    // Projects, not just any folder Claude was opened in.
                    && fm.fileExists(atPath: url.appendingPathComponent(".git").path)
            }
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { ProjectSuggestion(path: $0.key, lastUsed: $0.value, icon: ProjectIcons.findIcon(in: URL(fileURLWithPath: $0.key))) }
    }
}
