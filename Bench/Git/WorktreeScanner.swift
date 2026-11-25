import AppKit
import BenchKit
import Foundation

/// Lists the worktrees you made yourself under their projects. Looks when
/// the app starts, when a project is added, when you come back to the app,
/// and every so often for ones made in a terminal here, where nothing else
/// would announce them.
final class WorktreeScanner {
    private weak var store: AppStore?
    private var isScanning = false
    private var scanAgain = false
    private var timer: Timer?

    init(store: AppStore) {
        self.store = store
        store.onWorktreeLookNeeded = { [weak self] in self?.scan() }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scan() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scan() }
        }
        scan()
    }

    func scan() {
        guard !isScanning else {
            scanAgain = true
            return
        }
        isScanning = true
        Task {
            await lookThroughProjects()
            isScanning = false
            if scanAgain {
                scanAgain = false
                scan()
            }
        }
    }

    private func lookThroughProjects() async {
        guard let projects = store?.topLevelProjects else { return }
        for project in projects {
            // Skips plain folders without starting git for them.
            guard FileManager.default.fileExists(atPath: project.url.appendingPathComponent(".git").path),
                  let listed = await Worktrees.list(repo: project.url) else { continue }
            store?.syncWorktrees(of: project.id, listed: listed)
        }
    }
}
