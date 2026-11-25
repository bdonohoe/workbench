import BenchKit
import Foundation

/// Creates and removes the git worktrees that give each agent its own
/// branch and folder. `WorktreePaths` has the rules for where they go.
nonisolated enum Worktrees {
    struct Failure: Error, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// The settings key for the folder new worktrees go in.
    static let chosenFolderKey = "worktreesFolder"

    /// The folder you picked for new worktrees, or nil for next to each repo.
    static var chosenFolder: URL? {
        guard let path = UserDefaults.standard.string(forKey: chosenFolderKey), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Where a branch's worktree goes for a project.
    static func folder(forRepo repo: URL, branch: String) -> URL {
        WorktreePaths.folder(forRepo: repo, branch: branch, chosenFolder: chosenFolder)
    }

    /// The repo a worktree belongs to, asked of git, since the worktree
    /// could be anywhere. nil if its folder is gone or git can't tell.
    static func repo(ofWorktree worktree: URL) async -> URL? {
        guard let path = await GitClient(root: worktree).optionalString(["rev-parse", "--path-format=absolute", "--git-common-dir"]),
              path.hasSuffix("/.git") else { return nil }
        return URL(fileURLWithPath: path).deletingLastPathComponent()
    }

    /// Branches already checked out somewhere, mapped to their folders.
    /// Git refuses to check out one branch in two worktrees.
    static func checkedOutBranches(repo: URL) async -> [String: String] {
        var result: [String: String] = [:]
        for entry in await list(repo: repo) ?? [] {
            if let branch = entry.branch { result[branch] = entry.path }
        }
        return result
    }

    /// Every worktree git knows about for a repo, wherever it lives, with
    /// the main one first. nil if git couldn't answer.
    static func list(repo: URL) async -> [WorktreeList.Entry]? {
        guard let text = try? await GitClient(root: repo).string(["worktree", "list", "--porcelain"]) else { return nil }
        return WorktreeList.parse(text)
    }

    /// Makes a worktree for `branch`, creating the branch from `base` if it
    /// doesn't exist yet. Returns its folder.
    static func create(repo: URL, branch: String, base: String?) async throws -> URL {
        let git = GitClient(root: repo)
        let branch = branch.trimmingCharacters(in: .whitespaces)
        guard !branch.isEmpty, await git.optionalString(["check-ref-format", "--branch", branch]) != nil else {
            throw Failure(message: "“\(branch)” isn't a valid branch name.")
        }
        if let path = await checkedOutBranches(repo: repo)[branch] {
            throw Failure(message: "\(branch) is already checked out in \(URL(fileURLWithPath: path).lastPathComponent). Pick another branch name.")
        }
        // Don't quietly recreate a folder that's gone, like one on a drive
        // that isn't plugged in.
        if let chosenFolder, !FileManager.default.fileExists(atPath: chosenFolder.path) {
            throw Failure(message: "The folder for new worktrees, \(chosenFolder.path), isn't there. Choose another in Settings > General.")
        }
        let folder = folder(forRepo: repo, branch: branch)
        if FileManager.default.fileExists(atPath: folder.path) {
            throw Failure(message: "There's already a folder at \(folder.path).")
        }
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        let exists = await git.optionalString(["rev-parse", "--verify", "-q", "refs/heads/\(branch)"]) != nil
        do {
            if exists {
                _ = try await git.run(["worktree", "add", folder.path, branch])
            } else {
                _ = try await git.run(["worktree", "add", "-b", branch, folder.path] + (base.map { [$0] } ?? []))
            }
        } catch {
            throw Failure(message: String(describing: error))
        }
        return folder
    }

    /// Copies setup files (like .env) from the repo into a new worktree.
    /// Missing files are skipped. Returns the ones that were copied.
    @discardableResult
    static func copy(_ files: [String], from repo: URL, to worktree: URL) -> [String] {
        let fm = FileManager.default
        var copied: [String] = []
        for file in files {
            let name = file.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains("..") else { continue }
            let source = repo.appendingPathComponent(name)
            let target = worktree.appendingPathComponent(name)
            guard fm.fileExists(atPath: source.path), !fm.fileExists(atPath: target.path) else { continue }
            try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? fm.copyItem(at: source, to: target)) != nil { copied.append(name) }
        }
        return copied
    }

    /// Files people usually keep out of git but need to run the project.
    static func suggestedSetupFiles(repo: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: repo.path)) ?? []
        return names.filter { $0.hasPrefix(".env") && !$0.hasSuffix(".example") && !$0.hasSuffix(".sample") }.sorted()
    }

    /// What would be lost by removing a worktree.
    enum Leftovers: Equatable {
        case none
        case uncommitted
        case unpushed
        /// git couldn't answer, so assume the worst.
        case unknown

        var summary: String {
            switch self {
            case .none: "Merged"
            case .uncommitted: "Merged, has uncommitted changes"
            case .unpushed: "Merged, has unpushed commits"
            case .unknown: "Merged, couldn't check for changes"
            }
        }
    }

    /// Checks a worktree for uncommitted changes and for commits that
    /// aren't pushed. When the merged PR ended on the worktree's current
    /// commit, nothing new was made since, even if GitHub has deleted the
    /// branch. Any git error counts as "unknown".
    static func leftovers(_ worktree: URL, branch: String?, mergedHead: String? = nil) async -> Leftovers {
        guard FileManager.default.fileExists(atPath: worktree.path) else { return .none }
        let git = GitClient(root: worktree)
        guard let status = try? await git.string(["status", "--porcelain"]) else { return .unknown }
        if !status.isEmpty { return .uncommitted }
        if let mergedHead, let head = try? await git.string(["rev-parse", "HEAD"]), head == mergedHead {
            return .none
        }
        // Commits on this branch that its upstream (or origin/<branch>)
        // doesn't have.
        var upstream = (try? await git.string(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"])) ?? ""
        if upstream.isEmpty, let branch { upstream = "origin/\(branch)" }
        guard !upstream.isEmpty, let count = try? await git.string(["rev-list", "--count", "\(upstream)..HEAD"]),
              let ahead = Int(count) else { return .unknown }
        return ahead > 0 ? .unpushed : .none
    }

    /// True if the worktree has changes that aren't committed, or git
    /// can't tell.
    static func hasUncommittedChanges(_ worktree: URL) async -> Bool {
        guard FileManager.default.fileExists(atPath: worktree.path) else { return false }
        guard let status = try? await GitClient(root: worktree).string(["status", "--porcelain"]) else { return true }
        return !status.isEmpty
    }

    /// The settings key for moving removed worktrees to the Trash. Off by
    /// default: worktrees are big (dependencies, build output) and pile up
    /// there, so they're deleted outright unless you ask otherwise.
    static let trashKey = "trashRemovedWorktrees"

    /// True if removed worktrees go to the Trash, not straight to deletion.
    static var movesToTrash: Bool { UserDefaults.standard.bool(forKey: trashKey) }

    /// What happens to a removed worktree's folder, for confirmations.
    static var removalPhrase: String { movesToTrash ? "moves to the Trash" : "is deleted permanently" }

    /// The end of the name a folder gets while it's being deleted.
    private static let doomedSuffix = ".bench-deleting"

    /// One deletion at a time, so two never work through the same folder.
    private static let deletions = DispatchQueue(label: "bench.worktree-deletions", qos: .utility)

    /// Takes a worktree's folder away: deleted for good, or moved to the
    /// Trash (so ignored files like .env can still be recovered) if that's
    /// what Settings says. The step that can fail (permissions, a volume
    /// without a Trash, a synced folder), so it comes first, before
    /// anything that's hard to undo.
    ///
    /// Deleting a big folder takes a while, so the folder is renamed out
    /// of the way, which is instant and either works or changes nothing,
    /// and its contents are deleted in the background. The returned task
    /// ends when they're gone.
    @discardableResult
    static func removeFolder(worktree: URL, toTrash: Bool = movesToTrash) throws -> Task<Void, Never>? {
        guard FileManager.default.fileExists(atPath: worktree.path) else { return nil }
        if toTrash {
            do {
                try FileManager.default.trashItem(at: worktree, resultingItemURL: nil)
            } catch {
                throw Failure(message: "Couldn't move \(worktree.lastPathComponent) to the Trash: \(error.localizedDescription)")
            }
            return nil
        }
        let shared = worktree.deletingLastPathComponent()
        let doomed = shared.appendingPathComponent(".\(worktree.lastPathComponent).\(UUID().uuidString.prefix(8))\(doomedSuffix)")
        do {
            try FileManager.default.moveItem(at: worktree, to: doomed)
        } catch {
            throw Failure(message: "Couldn't delete \(worktree.lastPathComponent): \(error.localizedDescription)")
        }
        return Task.detached(priority: .utility) {
            await withCheckedContinuation { done in
                deletions.async {
                    deleteDoomedFolders(in: shared)
                    removeIfEmpty(shared)
                    done.resume()
                }
            }
        }
    }

    /// Deletes every folder waiting to be deleted in a worktrees folder,
    /// including any left by a deletion that Workbench quit in the middle of.
    private static func deleteDoomedFolders(in shared: URL) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: shared.path)) ?? []
        where name.hasPrefix(".") && name.hasSuffix(doomedSuffix) {
            let folder = shared.appendingPathComponent(name)
            // Something still running in there can add files mid-delete.
            // Its terminals are closed by now, so a second pass gets them.
            if (try? fm.removeItem(at: folder)) == nil { try? fm.removeItem(at: folder) }
        }
    }

    /// Cleans up the shared worktrees folder once its last worktree is gone.
    private static func removeIfEmpty(_ shared: URL) {
        if WorktreePaths.canRemoveWhenEmpty(shared, chosenFolder: chosenFolder),
           (try? FileManager.default.contentsOfDirectory(atPath: shared.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: shared)
        }
    }

    /// Removes a worktree's folder, tells git it's gone, and deletes its
    /// branch if asked.
    static func remove(worktree: URL, branch: String?, repo: URL, deleteBranch: Bool) async throws {
        let git = GitClient(root: repo)
        try removeFolder(worktree: worktree)
        _ = try? await git.run(["worktree", "prune"])
        removeIfEmpty(worktree.deletingLastPathComponent())
        if deleteBranch, let branch {
            // -D: a squash-merged branch looks unmerged to git. Its last
            // commit stays in git's reflog for a while either way.
            _ = try? await git.run(["branch", "-D", branch])
        }
    }

    /// A branch name from the first words of a prompt, like
    /// "feat/add-dark-mode-toggle" or "fix/crash-on-launch".
    static func suggestBranch(from prompt: String) -> String {
        BranchNames.suggest(from: prompt)
    }
}
