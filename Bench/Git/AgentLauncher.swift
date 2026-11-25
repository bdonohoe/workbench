import BenchKit
import Foundation

/// Starts an agent on its own branch: makes the worktree, copies setup
/// files, adds the project, and starts its tabs right away so the setup
/// command runs without anyone opening the tab. Used by the New Agent
/// sheet and by the phone.
enum AgentLauncher {
    @discardableResult
    /// `savesSetup` remembers the files and command for the project's next
    /// agent, as the New Agent sheet does when you edit them.
    static func start(parent: Project, branch: String, base: String?, prompt: String?, files: [String], command: String?,
                      select: Bool = true, savesSetup: Bool = true, store: AppStore, terminals: TerminalManager,
                      agent: AgentID? = nil, prepare: ((URL) throws -> Void)? = nil) async throws -> UUID {
        let branch = branch.trimmingCharacters(in: .whitespaces)
        let command = command?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let folder = try await Worktrees.create(repo: parent.url, branch: branch, base: base)
        Worktrees.copy(files, from: parent.url, to: folder)
        // Before Claude opens, so whatever it's asked to read is there.
        do {
            try prepare?(folder)
        } catch {
            try? await Worktrees.remove(worktree: folder, branch: branch, repo: parent.url, deleteBranch: true)
            throw error
        }
        if savesSetup { store.setWorktreeSetup(files: files, command: command, for: parent.id) }
        let id = store.addWorktree(parent: parent, path: folder.path, branch: branch, base: base, prompt: prompt, setupCommand: command, select: select, agent: agent)
        if let worktree = store.project(id) {
            for tab in worktree.tabs { _ = terminals.session(for: tab, in: worktree) }
        }
        return id
    }

    /// The branch new agents start from: main (without `origin/`) if it
    /// exists locally, else the checked-out branch, else the first one.
    nonisolated static func preferredBase(repo: URL) async -> String? {
        let git = GitClient(root: repo)
        async let list = git.branches()
        async let current = git.currentBranch()
        async let fallback = git.defaultBase()
        let (all, here, main) = await (list, current, fallback)
        let preferred = main.map { $0.hasPrefix("origin/") ? String($0.dropFirst("origin/".count)) : $0 }
        return [preferred, here].compactMap { $0 }.first { all.contains($0) } ?? all.first
    }

    /// Starts each task one at a time without moving the selection.
    /// Returns the failures by task id; empty when everything started.
    static func startAll(_ tasks: [DraftTask], store: AppStore, terminals: TerminalManager) async -> [UUID: String] {
        var failures: [UUID: String] = [:]
        for task in tasks {
            guard let projectID = task.projectID, let parent = store.project(projectID) else {
                failures[task.id] = "This project is no longer in Workbench."
                continue
            }
            do {
                try await start(parent: parent, branch: task.branch.trimmingCharacters(in: .whitespaces),
                                base: await preferredBase(repo: parent.url), prompt: task.prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                                files: parent.setupFiles ?? Worktrees.suggestedSetupFiles(repo: parent.url),
                                command: parent.setupCommand, select: false, store: store, terminals: terminals)
            } catch {
                failures[task.id] = error.localizedDescription
            }
        }
        return failures
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
