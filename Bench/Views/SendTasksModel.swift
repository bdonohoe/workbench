import BenchKit
import Foundation
import Observation

/// The Send Tasks sheet's state: one message, split by Claude into tasks
/// you check and edit before any agent starts.
@Observable
final class SendTasksModel {
    enum Step { case write, splitting, review, starting }

    var step = Step.write
    var message = ""
    var tasks: [DraftTask] = []
    var error: String?
    /// Why a task didn't start, by task id.
    var startErrors: [UUID: String] = [:]
    var projects: [SplitProject] = []

    /// Set when the tasks go to another Mac, which splits and starts them.
    let remote: CompanionClient?
    private var repos: [UUID: URL] = [:]
    /// Who splits the message: the selected project's account, the one the
    /// sidebar's usage rings are showing.
    private var profile = ClaudeProfile.main()
    /// Branches already in each project's repo.
    private var existing: [UUID: Set<String>] = [:]
    /// Projects whose branches are still being read.
    private var loading: Set<UUID> = []
    /// Bumped to drop a split whose reply is no longer wanted.
    private var generation = 0

    /// What blocks each task from starting, by task id.
    var problems: [UUID: String] {
        TaskSplit.problems(tasks, existing: existing,
                           names: Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.name) }))
    }

    /// Also waits for branch names to load, so a clash can't slip through.
    var canStart: Bool { !tasks.isEmpty && problems.isEmpty && loading.isEmpty }

    init(remote: CompanionClient? = nil) {
        self.remote = remote
    }

    func load(from store: AppStore) {
        if let remote {
            // Until the other Mac answers, its top-level projects stand in.
            projects = (remote.snapshot?.projects ?? []).filter { $0.parentID == nil }
                .map { SplitProject(id: $0.id, name: $0.name, summary: "") }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return
        }
        projects = TaskSplitter.projects(in: store)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        repos = TaskSplitter.repos(in: store)
        profile = store.selectedProjectID.map { ClaudeAccounts.shared.profile(store.claudeAccountID(for: $0)) } ?? .main()
    }

    func split() {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, step == .write else { return }
        generation += 1
        let current = generation
        step = .splitting
        error = nil
        if let remote {
            remote.splitTasks(message: text)
            return
        }
        let projects = projects, repos = repos, profile = profile
        Task {
            let result = await TaskSplitter.split(text, projects: projects, repos: repos, profile: profile)
            guard current == generation else { return }
            switch result {
            case .success(let found):
                tasks = found
                startErrors = [:]
                existing = [:]
                step = .review
                for id in Set(found.compactMap(\.projectID)) { loadBranches(id) }
            case .failure(let failure):
                error = failure.message
                step = .write
            }
        }
    }

    /// The other Mac's split, for a remote model.
    func receive(_ result: TaskSplitResult) {
        guard step == .splitting else { return }
        if let problem = result.problem {
            error = problem
            step = .write
            return
        }
        tasks = result.tasks
        projects = result.projects
        existing = result.existingBranches.mapValues(Set.init)
        startErrors = [:]
        step = .review
    }

    /// Which tasks the other Mac couldn't start. True when all of them did.
    func receive(failures: [UUID: String]) -> Bool {
        guard step == .starting else { return false }
        tasks.removeAll { failures[$0.id] == nil }
        startErrors = failures
        step = failures.isEmpty ? .starting : .review
        return failures.isEmpty
    }

    /// The other Mac couldn't take the request, or went away.
    func remoteFailed(_ problem: String) {
        switch step {
        case .splitting: error = problem; step = .write
        case .starting: error = problem; step = .review
        default: break
        }
    }

    /// Back to the message, text intact. Splitting again replaces the tasks.
    func editMessage() {
        step = .write
    }

    func addTask() {
        tasks.append(DraftTask())
    }

    func remove(_ id: UUID) {
        tasks.removeAll { $0.id == id }
        startErrors[id] = nil
    }

    func setProject(_ projectID: UUID?, for taskID: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[index].projectID = projectID
        tasks[index].unsure = nil
        if let projectID, existing[projectID] == nil { loadBranches(projectID) }
    }

    /// Drops a split still in flight. The sheet calls this when it closes.
    func cancelSplit() {
        generation += 1
        remote?.clearTaskSplit()
    }

    /// Starts every task. Ones that fail stay, with their errors. True when
    /// all of them started.
    func start(store: AppStore, terminals: TerminalManager) async -> Bool {
        guard canStart, step == .review else { return false }
        step = .starting
        startErrors = [:]
        error = nil
        if let remote {
            remote.startTasks(tasks)
            return false
        }
        let failures = await AgentLauncher.startAll(tasks, store: store, terminals: terminals)
        Analytics.capture(.agentStarted, ["kind": "send_tasks", "count": tasks.count - failures.count, "from_phone": false])
        tasks.removeAll { failures[$0.id] == nil }
        startErrors = failures
        guard !failures.isEmpty else { return true }
        // A failed start can leave a branch behind; read them again.
        for id in Set(tasks.compactMap(\.projectID)) { loadBranches(id) }
        step = .review
        return false
    }

    private func loadBranches(_ projectID: UUID) {
        guard let repo = repos[projectID], !loading.contains(projectID) else { return }
        loading.insert(projectID)
        Task {
            let branches = await TaskSplitter.existingBranches(repo: repo)
            existing[projectID] = branches
            loading.remove(projectID)
        }
    }
}
