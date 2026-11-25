import CoreServices
import Foundation
import Observation

/// Keeps a live git snapshot for one project, refreshing when files change.
@Observable
final class RepoMonitor {
    let projectID: UUID
    let client: GitClient
    private(set) var snapshot: GitSnapshot?
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?
    /// Local and remote branches, most recently committed first, for the base picker.
    private(set) var branches: [String] = []

    /// nil means auto-detect (origin's default branch, then main/master).
    var baseOverride: String? {
        didSet { if oldValue != baseOverride { refreshSoon(delay: .zero) } }
    }

    @ObservationIgnored private var stream: FSEventStreamRef?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var needsAnotherRefresh = false

    init(project: Project) {
        projectID = project.id
        client = GitClient(root: project.url)
        baseOverride = project.baseRef
    }

    deinit {
        MainActor.assumeIsolated { stopWatching() }
    }

    // MARK: Refresh

    func refreshSoon(delay: Duration = .milliseconds(250)) {
        pending?.cancel()
        pending = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    func refresh() {
        // Coalesce: if a refresh is running, run exactly one more afterwards.
        guard refreshTask == nil else {
            needsAnotherRefresh = true
            return
        }
        isRefreshing = true
        let client = client
        let base = baseOverride
        refreshTask = Task { [weak self] in
            let result = await client.snapshot(baseOverride: base)
            guard let self else { return }
            if self.snapshot != result { self.snapshot = result }
            self.lastRefresh = .now
            self.isRefreshing = false
            self.refreshTask = nil
            if self.needsAnotherRefresh {
                self.needsAnotherRefresh = false
                self.refresh()
            }
        }
    }

    // MARK: Watching

    func loadBranches() {
        let client = client
        Task { [weak self] in
            let list = await client.branches()
            self?.branches = list
        }
    }

    func startWatching() {
        guard stream == nil else { return }
        refresh()
        loadBranches()

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let monitor = Unmanaged<RepoMonitor>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            // Object database churn (fetch, gc) doesn't change anything we show.
            let relevant = list.prefix(count).contains { !$0.contains("/.git/objects/") && !$0.contains("/.git/logs/") }
            guard relevant else { return }
            MainActor.assumeIsolated { monitor.refreshSoon() }
        }
        // A worktree's index and HEAD live in the main repo's .git folder,
        // so watch that too, or commits there wouldn't refresh the panel.
        let paths = ([client.root.path] + (Self.linkedGitDir(client.root).map { [$0] } ?? [])) as CFArray
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2,
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    /// For a worktree, `.git` is a file that says "gitdir: <path>".
    private static func linkedGitDir(_ root: URL) -> String? {
        guard let text = try? String(contentsOf: root.appendingPathComponent(".git"), encoding: .utf8),
              text.hasPrefix("gitdir: ") else { return nil }
        let path = text.dropFirst("gitdir: ".count).trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: path, relativeTo: root).standardizedFileURL.path
    }

    func stopWatching() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}

/// One monitor per project, created on demand.
@Observable
final class RepoMonitors {
    // Created lazily from view bodies, so changes here must not invalidate views.
    @ObservationIgnored private var monitors: [UUID: RepoMonitor] = [:]

    func monitor(for project: Project) -> RepoMonitor {
        if let existing = monitors[project.id] { return existing }
        let monitor = RepoMonitor(project: project)
        monitors[project.id] = monitor
        return monitor
    }

    /// Only the selected project's repo is watched; others refresh when selected.
    func focus(on projectID: UUID?) {
        for (id, monitor) in monitors where id != projectID { monitor.stopWatching() }
        if let projectID, let monitor = monitors[projectID] { monitor.startWatching() }
    }

    func prune(keeping ids: Set<UUID>) {
        for (id, monitor) in monitors where !ids.contains(id) {
            monitor.stopWatching()
            monitors[id] = nil
        }
    }
}
