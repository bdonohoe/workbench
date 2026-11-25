import BenchKit
import AppKit
import Observation
import SwiftUI
import UserNotifications

/// Tidies up an agent's worktree once its pull request merges, and
/// handles Discard. By default a merged agent waits for you to click
/// Clean Up. With automatic cleanup on, Bench removes it by itself, but
/// only when nothing would be lost: no uncommitted changes, no unpushed
/// commits, and git answered both questions. Removed folders are deleted
/// for good, or go to the Trash if Settings says so.
@Observable
final class WorktreeCleaner {
    /// The settings key for automatic cleanup.
    static let autoCleanKey = "autoCleanMergedWorktrees"

    /// Merged worktrees waiting for you, with what's left in each.
    private(set) var waiting: [UUID: Worktrees.Leftovers] = [:]

    @ObservationIgnored private weak var store: AppStore?
    @ObservationIgnored private weak var terminals: TerminalManager?
    @ObservationIgnored private weak var pullRequests: PullRequests?
    @ObservationIgnored private var inFlight: Set<UUID> = []
    @ObservationIgnored private var timer: Timer?

    init(store: AppStore, terminals: TerminalManager, pullRequests: PullRequests) {
        self.store = store
        self.terminals = terminals
        self.pullRequests = pullRequests
        // PR status updates itself; this also catches Claude going idle
        // after the merge, and new commits made since.
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweep() }
        }
    }

    private var autoClean: Bool { UserDefaults.standard.bool(forKey: Self.autoCleanKey) }

    /// Looks at every merged worktree whose agent isn't busy: removes it if
    /// automatic cleanup is on and it's safe, otherwise marks it as waiting.
    func sweep() {
        guard let store, let terminals, let pullRequests else { return }
        for worktree in store.projects where worktree.isWorktree && !worktree.isExternalWorktree {
            guard let pr = pullRequests.info[worktree.id], pr.state == .merged, !inFlight.contains(worktree.id) else { continue }
            // Leave it alone while Claude is still doing something there.
            switch terminals.activity(for: worktree) {
            case .working, .remoteWorking, .waiting: continue
            default: break
            }
            inFlight.insert(worktree.id)
            Task {
                let leftovers = await Worktrees.leftovers(worktree.url, branch: worktree.branch, mergedHead: pr.headCommit)
                if leftovers == .none, autoClean {
                    do {
                        try await remove(worktree)
                        notifyCleaned(worktree)
                    } catch {
                        waiting[worktree.id] = .unknown
                    }
                } else if waiting[worktree.id] != leftovers {
                    waiting[worktree.id] = leftovers
                }
                inFlight.remove(worktree.id)
            }
        }
    }

    /// Clean Up for a merged worktree.
    func cleanUp(_ worktree: Project) {
        let leftovers = waiting[worktree.id] ?? .none
        let warning: String = switch leftovers {
        case .none: ""
        case .uncommitted: " It has uncommitted changes, which will be lost."
        case .unpushed: " It has commits that were never pushed. Its branch will be deleted, so they'll only be recoverable from git's reflog."
        case .unknown: " Workbench couldn't check it for uncommitted changes or unpushed commits."
        }
        confirmAndRemove(worktree, title: "Clean up \(worktree.branch ?? worktree.name)?",
                         message: "Its pull request is merged. The folder \(Worktrees.removalPhrase) and its local branch is deleted." + warning,
                         critical: leftovers != .none, button: "Clean Up")
    }

    /// Clean Up for several merged worktrees at once, with one question.
    /// Any that would lose work are named in it.
    func cleanUp(_ worktrees: [Project]) {
        guard worktrees.count > 1 else {
            if let worktree = worktrees.first { cleanUp(worktree) }
            return
        }
        let risky = worktrees.filter { (waiting[$0.id] ?? .none) != .none }
        var message = "Their pull requests are merged. The folders \(Worktrees.movesToTrash ? "move to the Trash" : "are deleted permanently") and their local branches are deleted."
        if !risky.isEmpty {
            let names = risky.map { $0.branch ?? $0.name }.joined(separator: ", ")
            message += risky.count == 1
                ? " \(names) may have uncommitted changes or unpushed commits, which will be lost."
                : " These may have uncommitted changes or unpushed commits, which will be lost: \(names)."
        }
        let alert = NSAlert()
        alert.messageText = "Clean up \(worktrees.count) merged worktrees?"
        alert.informativeText = message
        alert.alertStyle = risky.isEmpty ? .warning : .critical
        alert.addButton(withTitle: "Clean Up").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            var failures: [String] = []
            for worktree in worktrees {
                do {
                    try await remove(worktree)
                } catch {
                    failures.append("\(worktree.branch ?? worktree.name): \(error.localizedDescription)")
                }
            }
            guard !failures.isEmpty else { return }
            let failed = NSAlert()
            failed.messageText = failures.count == 1 ? "One worktree couldn't be cleaned up" : "\(failures.count) worktrees couldn't be cleaned up"
            failed.informativeText = failures.joined(separator: "\n")
            failed.runModal()
        }
    }

    /// Throws an agent's work away: its worktree folder and its branch.
    func discard(_ worktree: Project) {
        Task {
            let dirty = await Worktrees.hasUncommittedChanges(worktree.url)
            confirmAndRemove(worktree, title: "Discard \(worktree.branch ?? worktree.name)?",
                             message: "The agent's worktree folder \(Worktrees.removalPhrase) and its local branch is deleted. Anything already pushed stays on GitHub."
                                + (dirty ? " It has uncommitted changes." : ""),
                             critical: dirty, button: "Discard")
        }
    }

    /// Clean Up or Discard asked for from another device, which has
    /// already confirmed with its own warning.
    func removeForRemote(_ worktree: Project) async throws {
        try await remove(worktree)
    }

    /// A merged worktree's state for other devices, or nil if it isn't
    /// waiting to be cleaned up.
    func companionCleanup(_ id: UUID) -> CompanionCleanup? {
        switch waiting[id] {
        case nil: nil
        case .none?: .ready
        case .uncommitted?: .uncommitted
        case .unpushed?: .unpushed
        case .unknown?: .unknown
        }
    }

    private func confirmAndRemove(_ worktree: Project, title: String, message: String, critical: Bool, button: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = critical ? .critical : .warning
        alert.addButton(withTitle: button).hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do {
                try await remove(worktree)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    private func remove(_ worktree: Project) async throws {
        guard let store else { return }
        // Every removal comes through here, including from a phone that
        // doesn't know to hide the button.
        guard !worktree.isExternalWorktree else {
            throw Worktrees.Failure(message: "\(worktree.branch ?? worktree.name) was made outside Workbench, so Workbench won't delete it.")
        }
        // Without its project, ask git. If the folder's already gone too,
        // the repo may sit next to the "<repo>.worktrees" folder it was in.
        var repo = worktree.parentID.flatMap { store.project($0) }?.url
        if repo == nil { repo = await Worktrees.repo(ofWorktree: worktree.url) }
        let container = worktree.url.deletingLastPathComponent()
        let repoFolder = container.lastPathComponent.hasSuffix(".worktrees")
            ? String(container.lastPathComponent.dropLast(".worktrees".count)) : worktree.repoName
        let found = repo ?? container.deletingLastPathComponent().appendingPathComponent(repoFolder)
        // The folder first: if that fails, the project stays in the sidebar
        // with its error. Removing the project first left the folder and
        // branch behind, and the scanner then brought it back as a
        // worktree made outside Workbench, which Workbench won't delete.
        try Worktrees.removeFolder(worktree: worktree.url)
        // Then close its terminals, so nothing is left running in a
        // folder that's gone.
        store.removeProject(worktree.id)
        waiting[worktree.id] = nil
        try await Worktrees.remove(worktree: worktree.url, branch: worktree.branch, repo: found, deleteBranch: true)
    }

    private func notifyCleaned(_ worktree: Project) {
        let content = UNMutableNotificationContent()
        content.title = "Cleaned up \(worktree.branch ?? worktree.name)"
        content.body = Worktrees.movesToTrash
            ? "Its pull request merged, so its worktree went to the Trash."
            : "Its pull request merged, so its worktree was deleted."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "cleaned-\(worktree.id)", content: content, trigger: nil))
    }
}

