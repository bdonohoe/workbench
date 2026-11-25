import BenchKit
import SwiftUI

/// The right-hand panel: git status, changes against a base, and commits.
struct ChangesPanel: View {
    @Environment(AppStore.self) private var store
    @Environment(RepoMonitors.self) private var monitors
    @Environment(TerminalManager.self) private var terminals
    @Environment(ClaudeActions.self) private var actions
    @Environment(PullRequests.self) private var pullRequests
    @Environment(ProjectIcons.self) private var icons
    let project: Project
    /// How many of the files this project's Claude edited in each other
    /// project are still changed there.
    @State private var stillChanged: [UUID: Int] = [:]

    var body: some View {
        let monitor = monitors.monitor(for: project)
        let elsewhere = terminals.editsInOtherProjects(from: project)
        Group {
            if let snapshot = monitor.snapshot {
                if snapshot.isRepository {
                    ChangesList(
                        snapshot: snapshot.changesSnapshot(branches: monitor.branches, chosenBase: project.baseRef),
                        selectedDiffID: store.selectedDiff?.id,
                        openDiff: { store.openDiff($0, in: project.id) },
                        refresh: {
                            monitor.refresh()
                            monitor.loadBranches()
                        },
                        chooseBase: { ref in
                            store.setBaseRef(ref, for: project.id)
                            monitor.baseOverride = ref
                        },
                        actions: actions.all,
                        pullRequest: pullRequests.info[project.id],
                        isWaitingToMerge: pullRequests.mergeWhenReady[project.id] != nil,
                        otherProjects: otherProjects(elsewhere)
                    ) { file in
                        menu(for: file)
                    } keepDiff: { file in
                        store.openDiff(file, in: project.id, keep: true)
                    } openFile: { file in
                        store.openFile(file.path, in: project.id)
                    } revealFile: { file in
                        NSWorkspace.shared.activateFileViewerSelecting([project.url.appendingPathComponent(file.path)])
                    } openCommit: { commit in
                        store.openReview(.commit(commit), in: project.id)
                    } reviewBranch: {
                        store.openReview(.branch(snapshot.branch), in: project.id)
                    } reviewLatestTurn: {
                        guard let tab = TurnReview.latestClaudeTab(in: project, terminals: terminals) else { return }
                        store.openTurnReview(.turn(nil, inTab: tab), in: project.id)
                    } runAction: { prompt in
                        terminals.sendToClaude(prompt, in: project, send: true)
                    } mergeWhenReady: { prompt in
                        pullRequests.mergeWhenReady(project.id, prompt: prompt)
                    } cancelMerge: {
                        pullRequests.cancelMerge(project.id)
                    }
                } else {
                    // The inspector shows the files instead; this only
                    // shows for a moment if a repository goes away.
                    ContentUnavailableView("Not a Git Repository", systemImage: "folder",
                                           description: Text(project.name))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { monitors.focus(on: project.id) }
        .onChange(of: project.id) { _, id in monitors.focus(on: id) }
        .task(id: EditsKey(project: project.id, edits: elsewhere, refreshed: monitor.lastRefresh)) {
            // Again now and then, since a commit over there changes nothing here.
            while !Task.isCancelled {
                await countStillChanged(elsewhere)
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private struct EditsKey: Equatable {
        let project: UUID
        let edits: [UUID: [String: Date]]
        let refreshed: Date?
    }

    /// The other projects Claude edited from here, with what's still changed.
    private func otherProjects(_ elsewhere: [UUID: [String: Date]]) -> [OtherProjectChanges] {
        elsewhere.compactMap { id, files -> OtherProjectChanges? in
            guard let other = store.project(id) else { return nil }
            let count = stillChanged[id] ?? files.count
            guard count > 0 else { return nil }
            return OtherProjectChanges(id: id, name: other.name, icon: AnyView(ProjectIcon(project: other, image: icons.image(for: other), size: 14)),
                                       files: count, lastEdit: files.values.max() ?? .distantPast) {
                store.selectedProjectID = id
            }
        }
        .sorted { $0.lastEdit > $1.lastEdit }
    }

    /// Asks git in each other project which of the edited files still
    /// differ, so a project drops off once its changes are committed. A
    /// folder that isn't a repository counts the files that still exist.
    private func countStillChanged(_ elsewhere: [UUID: [String: Date]]) async {
        var counts: [UUID: Int] = [:]
        for (id, files) in elsewhere {
            guard let other = store.project(id) else { continue }
            let prefix = other.path.hasSuffix("/") ? other.path : other.path + "/"
            let relative = files.keys.map { String($0.dropFirst(prefix.count)) }
            if let data = try? await GitClient(root: other.url).run(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--"] + relative) {
                let status = GitClient.parseStatus(data)
                counts[id] = Set((status.staged + status.unstaged).map(\.path)).count
            } else {
                counts[id] = files.keys.filter { FileManager.default.fileExists(atPath: $0) }.count
            }
        }
        if !Task.isCancelled, counts != stillChanged { stillChanged = counts }
    }

    /// The same actions as a file in the Files tab, plus its diff. A
    /// deleted file is only in git now, so it can't be opened or shown.
    @ViewBuilder
    private func menu(for file: FileChange) -> some View {
        let exists = file.kind != .deleted
        Button("Show Changes") { store.openDiff(file, in: project.id) }
        if exists {
            Button("Open") { store.openFile(file.path, in: project.id) }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([project.url.appendingPathComponent(file.path)])
            }
        }
        Divider()
        CopyPathButtons(path: file.path, root: project.path)
    }
}

/// Branch, files, and commits, for a project on this Mac or another one.
/// Each caller says what clicking a file, refreshing, and picking a base do.
struct ChangesList<FileMenu: View>: View {
    let snapshot: ChangesSnapshot
    var selectedDiffID: String?
    let openDiff: (FileChange) -> Void
    /// nil hides the refresh button.
    var refresh: (() -> Void)?
    /// nil shows the base without a menu to change it.
    var chooseBase: ((String?) -> Void)?
    /// The Claude action buttons under the branch: Commit, Push, Open PR,
    /// and any you added. Shown when `runAction` is set.
    var actions: [ClaudeAction] = []
    /// The pull request already open for this branch, which turns Open PR
    /// into a link to it.
    var pullRequest: PullRequestInfo?
    /// Merge is waiting for this pull request's checks to pass.
    var isWaitingToMerge = false
    /// Other projects this project's Claude edited, with changes still
    /// there. Shown under this project's own changes.
    var otherProjects: [OtherProjectChanges] = []
    @ViewBuilder let fileMenu: (FileChange) -> FileMenu
    /// Double-clicking a file keeps its diff open in its own tab.
    var keepDiff: ((FileChange) -> Void)?
    /// The buttons a row shows on hover. nil hides each one.
    var openFile: ((FileChange) -> Void)?
    var revealFile: ((FileChange) -> Void)?
    /// Clicking a commit opens it on a review page. nil leaves commits as text.
    var openCommit: ((Commit) -> Void)?
    /// "Review All" on the base section opens the branch's whole change set.
    var reviewBranch: (() -> Void)?
    /// "Latest Turn" beside the branch opens what Claude's most recent
    /// turn changed. nil hides it.
    var reviewLatestTurn: (() -> Void)?
    /// Sends an action's filled-in prompt to Claude; returns why it
    /// couldn't. nil (a Mac you're only watching) hides the buttons.
    var runAction: ((String) -> String?)?
    /// Merge While checks are running: Workbench sends the prompt once they
    /// pass. nil leaves Merge greyed out until then.
    var mergeWhenReady: ((String) -> Void)?
    var cancelMerge: (() -> Void)?

    @State private var collapsed: Set<String> = []
    /// Why the last action didn't reach Claude, shown under the buttons.
    @State private var actionProblem: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    if let error = snapshot.error {
                        Text(error).font(.caption).foregroundStyle(Theme.Status.failed).padding(10)
                    }
                    if snapshot.staged.isEmpty && snapshot.unstaged.isEmpty && snapshot.againstBase.isEmpty {
                        EmptyStateScaffold(title: "No Changes",
                                           message: "Edits in this project show up here as they happen.",
                                           size: .compact) {
                            ChangesEmptyIllustration(appeared: $0, branch: snapshot.branch)
                        }
                        .environment(\.companionPalette, TerminalTheme.shared.chatPalette)
                        .padding(.vertical, 28)
                    }
                    fileSection("Staged", key: "staged", files: snapshot.staged)
                    fileSection("Unstaged", key: "unstaged", files: snapshot.unstaged)
                    fileSection("Against \(snapshot.baseRef ?? "base")", key: "base", files: snapshot.againstBase)
                    otherProjectsSection
                    commitsSection
                }
                .padding(.bottom, 12)
            }
        }
    }

    // MARK: Header

    /// Branch, how it stands against the base and the remote, and what
    /// Claude can do next. Laid out as aligned rows: the branch with its
    /// freshness and refresh, a Base and a Remote row that share a label
    /// column, then one row of actions that spills into a menu.
    private var header: some View {
        // Re-render every 30s so "4m ago" stays current.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 9) {
                branchRow(now: context.date)
                statusGrid
                if let runAction, !actions.isEmpty {
                    let items = actionItems(run: runAction)
                    if !items.isEmpty {
                        ActionsRow(items: items)
                    }
                    if isWaitingToMerge, let pullRequest {
                        Text(Self.waitingText(pullRequest))
                            .font(.ui(size: Theme.TypeScale.meta))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let actionProblem {
                        Text(actionProblem)
                            .font(.ui(size: Theme.TypeScale.meta))
                            .foregroundStyle(Theme.Status.failed)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.ui(size: 11))
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 10)
        }
    }

    private func branchRow(now: Date) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(Theme.accent)
            Text(snapshot.branch ?? "No branch")
                .font(.ui(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(snapshot.branch ?? "")
            Spacer(minLength: 6)
            if let reviewLatestTurn {
                Button("Latest Turn", action: reviewLatestTurn)
                    .buttonStyle(.link)
                    .font(.ui(size: 11))
                    .lineLimit(1)
                    .fixedSize()
                    .help("What the agent's most recent turn changed, on one page")
            }
            let ago = shortFreshness(now: now)
            if let refresh {
                Button(action: refresh) {
                    HStack(spacing: 4) {
                        if let ago { Text(ago) }
                        Image(systemName: "arrow.clockwise")
                    }
                    .font(.ui(size: Theme.TypeScale.meta))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(freshnessHelp(now: now, refreshable: true))
                .accessibilityLabel("Refresh")
            } else if let ago {
                Text(ago)
                    .font(.ui(size: Theme.TypeScale.meta))
                    .foregroundStyle(.secondary)
                    .help(freshnessHelp(now: now, refreshable: false))
            }
        }
    }

    /// Base and Remote, each a label, a name, and how it stands.
    private var statusGrid: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 5) {
            GridRow {
                RowLabel("Base")
                BasePicker(current: snapshot.baseRef, shortName: shortBase, chosen: snapshot.chosenBase,
                           branches: snapshot.branches ?? [], choose: chooseBase)
                HStack(spacing: 4) {
                    baseStatus
                    Spacer(minLength: 4)
                    TotalsLabel(files: snapshot.staged + snapshot.unstaged + snapshot.againstBase)
                        .font(.ui(size: Theme.TypeScale.meta))
                }
            }
            // A Mac on an older Bench doesn't send upstream details,
            // so don't claim the branch isn't pushed.
            if snapshot.branches != nil {
                GridRow {
                    RowLabel("Remote")
                    Text(snapshot.remoteName ?? "none")
                        .fontWeight(snapshot.remoteName == nil ? .regular : .medium)
                        .foregroundStyle(snapshot.remoteName == nil ? .secondary : .primary)
                        .lineLimit(1)
                    remoteStatus
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .help(snapshot.upstream.map { "Tracking \($0)" } ?? "This branch has no upstream yet")
            }
        }
    }

    /// "3 ahead · 1 behind", only the parts that aren't zero.
    @ViewBuilder
    private var baseStatus: some View {
        if let ahead = snapshot.aheadOfBase, let behind = snapshot.behindBase {
            if ahead == 0 && behind == 0 {
                Text("up to date").foregroundStyle(.secondary)
            } else {
                HStack(spacing: 4) {
                    if ahead > 0 { Count(ahead, "ahead") }
                    if ahead > 0 && behind > 0 { Dot() }
                    if behind > 0 { Count(behind, "behind") }
                }
                .lineLimit(1)
            }
        }
    }

    /// "2 to push · 1 to pull", "in sync", or "not pushed yet".
    @ViewBuilder
    private var remoteStatus: some View {
        if snapshot.remoteName == nil || snapshot.upstream == nil {
            Text("not pushed yet").foregroundStyle(.secondary)
        } else if let unpushed = snapshot.unpushed, let unpulled = snapshot.unpulled {
            if unpushed == 0 && unpulled == 0 {
                Text("in sync").foregroundStyle(.secondary)
            } else {
                HStack(spacing: 4) {
                    if unpushed > 0 { Count(unpushed, "to push") }
                    if unpushed > 0 && unpulled > 0 { Dot() }
                    if unpulled > 0 { Count(unpulled, "to pull") }
                }
                .lineLimit(1)
            }
        }
    }

    /// "4m ago" for the last fetch, beside the refresh arrow.
    private func shortFreshness(now: Date) -> String? {
        if let fetched = snapshot.lastFetch { return CommitRow.relative(fetched, now: now) }
        if snapshot.upstream != nil { return "never fetched" }
        return nil
    }

    /// "Fetched 4m ago. Forked from main 2d ago. Click to refresh."
    private func freshnessHelp(now: Date, refreshable: Bool) -> String {
        var parts: [String] = []
        if let fetched = snapshot.lastFetch {
            parts.append("Fetched \(CommitRow.relative(fetched, now: now)).")
        } else if snapshot.upstream != nil {
            parts.append("Never fetched.")
        }
        if let base = snapshot.baseRef, let forked = snapshot.forkedAt, snapshot.branch != base {
            parts.append("Forked from \(shortBase ?? base) \(CommitRow.relative(forked, now: now)).")
        }
        if refreshable { parts.append("Click to refresh.") }
        return parts.joined(separator: " ")
    }

    // MARK: Actions

    /// The Claude actions as items for the actions row. Commit greys out on
    /// a clean tree and Push when everything's pushed. Open PR hides on the
    /// base branch and becomes a link to the pull request once there is
    /// one. Merge shows only for an open pull request, and follows its checks.
    private func actionItems(run: @escaping (String) -> String?) -> [ActionItem] {
        actions.compactMap { action in
            let prompt = action.filledPrompt(branch: snapshot.branch, base: shortBase, pullRequest: pullRequest?.number)
            let id = action.id.uuidString
            switch action.role {
            case .merge:
                guard let pr = pullRequest, pr.state == .open || pr.state == .draft else { return nil }
                return mergeItem(action, id: id, pr: pr, prompt: prompt, run: run)
            case .pullRequest where pullRequest != nil:
                let pr = pullRequest!
                return ActionItem(id: id, title: pr.state == .merged ? "PR Merged" : "View PR", symbol: action.symbol,
                                  help: "#\(pr.number) \(pr.title)") { NSWorkspace.shared.open(pr.url) }
            case .pullRequest where snapshot.branch == nil || snapshot.branch == shortBase:
                return nil
            default:
                return ActionItem(id: id, title: action.name, symbol: action.symbol, help: "Asks the agent: \(prompt)",
                                  disabled: !isAvailable(action)) { actionProblem = run(prompt) }
            }
        }
    }

    /// Merge, by the pull request's checks: straight away once they've
    /// passed (or there are none), Merge When Ready while they run, and Fix
    /// Checks when they fail.
    private func mergeItem(_ action: ClaudeAction, id: String, pr: PullRequestInfo, prompt: String,
                           run: @escaping (String) -> String?) -> ActionItem {
        let checks = PullRequestDisplay.checksText(pr)
        if pr.state == .draft {
            return ActionItem(id: id, title: action.name, symbol: action.symbol, help: "#\(pr.number) is a draft",
                              disabled: true) {}
        }
        switch pr.checks {
        case .pending where isWaitingToMerge:
            return ActionItem(id: id, title: "Cancel Merge", symbol: "xmark.circle",
                              help: "Stop waiting to merge #\(pr.number)") { cancelMerge?() }
        case .pending:
            return ActionItem(id: id, title: mergeWhenReady == nil ? action.name : "Merge When Ready",
                              symbol: action.symbol,
                              help: "\(checks ?? "Checks running"). Workbench waits for them to pass, then asks the agent: \(prompt)",
                              disabled: mergeWhenReady == nil) {
                actionProblem = nil
                mergeWhenReady?(prompt)
            }
        case .failing:
            let fix = ClaudeAction.fixChecksPrompt(pullRequest: pr.number, failing: pr.failingNames)
            return ActionItem(id: id, title: "Fix Checks", symbol: "wrench.and.screwdriver",
                              help: "\(checks ?? "Checks failing"). Asks the agent: \(fix)") { actionProblem = run(fix) }
        case .passing, .none:
            return ActionItem(id: id, title: action.name, symbol: action.symbol,
                              help: "Asks the agent: \(prompt)") { actionProblem = run(prompt) }
        }
    }

    /// "Merges #42 when checks pass (3 of 5 so far)."
    static func waitingText(_ pr: PullRequestInfo) -> String {
        let progress = pr.totalCount > 0 ? " (\(pr.passedCount) of \(pr.totalCount) so far)" : ""
        return "Merges #\(pr.number) when its checks pass\(progress)."
    }

    private func isAvailable(_ action: ClaudeAction) -> Bool {
        switch action.role {
        case .commit:
            return !(snapshot.staged.isEmpty && snapshot.unstaged.isEmpty)
        case .push:
            // A Mac on an older Bench doesn't say, so don't grey it out.
            guard snapshot.branches != nil, snapshot.branch != nil else { return snapshot.branch != nil }
            if snapshot.upstream == nil { return true }
            return (snapshot.unpushed ?? 1) > 0
        case .pullRequest, .merge, .custom:
            return true
        }
    }

    /// The base without its remote: "main" for "origin/main". The full
    /// name stays in the picker's menu and tooltip.
    private var shortBase: String? {
        guard let base = snapshot.baseRef else { return nil }
        for remote in [snapshot.remoteName, "origin"].compactMap({ $0 }) where base.hasPrefix(remote + "/") {
            return String(base.dropFirst(remote.count + 1))
        }
        return base
    }

    // MARK: Files

    @ViewBuilder
    private func fileSection(_ title: String, key: String, files: [FileChange]) -> some View {
        if !files.isEmpty {
            Section {
                if !collapsed.contains(key) {
                    ForEach(groupByDirectory(files), id: \.directory) { group in
                        if !group.directory.isEmpty {
                            HStack {
                                Text(group.directory)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                                Spacer()
                                Text("\(group.files.count)")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.top, 6)
                            .padding(.bottom, 2)
                            .help(group.directory)
                        }
                        ForEach(group.files) { file in
                            FileRow(file: file, isSelected: selectedDiffID == file.id,
                                    openFile: file.kind == .deleted ? nil : openFile.map { open in { open(file) } },
                                    reveal: file.kind == .deleted ? nil : revealFile.map { reveal in { reveal(file) } }) {
                                openDiff(file)
                            }
                            .simultaneousGesture(TapGesture(count: 2).onEnded { keepDiff?(file) })
                            .contextMenu { fileMenu(file) }
                        }
                    }
                }
            } header: {
                DisclosureHeader(title: title, count: files.count, insets: Self.headerInsets,
                                 isCollapsed: collapsed.contains(key)) {
                    if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
                } trailing: {
                    if key == "base", let reviewBranch {
                        Button("Review All", action: reviewBranch)
                            .buttonStyle(.link)
                            .font(.ui(size: 11))
                            .help("Every change on this branch on one page")
                    }
                    TotalsLabel(files: files)
                }
                .background(Self.headerBackground)
            }
        }
    }

    private static var headerInsets: EdgeInsets { EdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12) }

    /// Section headers pin to the top while the list scrolls, so they need
    /// an opaque background in the panel's color.
    @ViewBuilder private static var headerBackground: some View {
        if let panel = TerminalTheme.shared.panel { panel } else { Rectangle().fill(.background) }
    }

    private struct DirectoryGroup {
        var directory: String
        var files: [FileChange]
    }

    private func groupByDirectory(_ files: [FileChange]) -> [DirectoryGroup] {
        var order: [String] = []
        var groups: [String: [FileChange]] = [:]
        for file in files {
            if groups[file.directory] == nil { order.append(file.directory) }
            groups[file.directory, default: []].append(file)
        }
        return order.map { DirectoryGroup(directory: $0, files: groups[$0] ?? []) }
    }

    // MARK: Other projects

    @ViewBuilder
    private var otherProjectsSection: some View {
        if !otherProjects.isEmpty {
            Section {
                if !collapsed.contains("elsewhere") {
                    ForEach(otherProjects) { other in
                        OtherProjectRow(other: other)
                    }
                }
            } header: {
                DisclosureHeader(title: "Also Changed", count: otherProjects.count, insets: Self.headerInsets,
                                 isCollapsed: collapsed.contains("elsewhere")) {
                    if collapsed.contains("elsewhere") { collapsed.remove("elsewhere") } else { collapsed.insert("elsewhere") }
                }
                .help("Other projects the agent edited from this one")
                .background(Self.headerBackground)
            }
        }
    }

    // MARK: Commits

    @ViewBuilder
    private var commitsSection: some View {
        if !snapshot.commits.isEmpty {
            Section {
                if !collapsed.contains("commits") {
                    // Re-render every 30s so "4m ago" stays current.
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(snapshot.commits) { commit in
                                if let openCommit {
                                    Button { openCommit(commit) } label: {
                                        CommitRow(commit: commit, now: context.date)
                                    }
                                    .buttonStyle(CommitRowStyle())
                                } else {
                                    CommitRow(commit: commit, now: context.date)
                                }
                            }
                        }
                    }
                }
            } header: {
                DisclosureHeader(title: "Commits", count: snapshot.commits.count, insets: Self.headerInsets,
                                 isCollapsed: collapsed.contains("commits")) {
                    if collapsed.contains("commits") { collapsed.remove("commits") } else { collapsed.insert("commits") }
                }
                .background(Self.headerBackground)
            }
        }
    }
}

// MARK: - Pieces

/// "Base", "Remote": the quiet label column of the header's status rows.
private struct RowLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.ui(size: Theme.TypeScale.meta))
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.leading)
    }
}

/// One Claude action, ready to show as a button or a menu item.
private struct ActionItem: Identifiable {
    let id: String
    let title: String
    let symbol: String
    var help: String
    var disabled = false
    let perform: () -> Void
}

/// The actions on one line: as many buttons as fit, the rest in a ⋯ menu.
private struct ActionsRow: View {
    let items: [ActionItem]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(Array(stride(from: items.count, through: 0, by: -1)), id: \.self) { shown in
                row(showing: shown)
            }
        }
    }

    private func row(showing shown: Int) -> some View {
        HStack(spacing: 6) {
            ForEach(items.prefix(shown)) { item in
                Button(action: item.perform) {
                    Label(item.title, systemImage: item.symbol)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(item.disabled)
                .help(item.help)
            }
            if shown < items.count {
                Menu {
                    ForEach(items.dropFirst(shown)) { item in
                        Button(action: item.perform) {
                            Label(item.title, systemImage: item.symbol)
                        }
                        .disabled(item.disabled)
                    }
                } label: {
                    // As tall as the labelled buttons beside it.
                    Label("More", systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                        .frame(height: 16)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
                .help("More actions")
                .accessibilityLabel("More actions")
            }
        }
        .fixedSize()
    }
}

private struct Dot: View {
    var body: some View { Text("·").foregroundStyle(.tertiary) }
}

/// "3 ahead": the number weighted, the word quiet.
private struct Count: View {
    let number: Int
    let word: String
    init(_ number: Int, _ word: String) { self.number = number; self.word = word }

    var body: some View {
        (Text("\(number)").fontWeight(.semibold) + Text(" \(word)"))
            .foregroundStyle(number > 0 ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .monospacedDigit()
    }
}

private struct FileRow: View {
    let file: FileChange
    let isSelected: Bool
    var openFile: (() -> Void)?
    var reveal: (() -> Void)?
    let action: () -> Void
    @State private var isHovering = false

    private var showsActions: Bool { isHovering && (openFile != nil || reveal != nil) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: FileIcon.symbol(for: file.fileName))
                    .font(.ui(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(file.fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .strikethrough(file.kind == .deleted, color: .secondary)
                Spacer(minLength: 6)
                if showsActions {
                    // In place of the counts while the pointer is on the row.
                    HStack(spacing: 2) {
                        if let openFile {
                            RowAction(symbol: "doc.text", help: "Open the whole file", action: openFile)
                        }
                        if let reveal {
                            RowAction(symbol: "folder", help: "Show in Finder", action: reveal)
                        }
                    }
                } else if file.isBinary {
                    Text("binary").font(.caption).foregroundStyle(.secondary)
                } else {
                    LineCounts(additions: file.additions, deletions: file.deletions)
                }
                KindBadge(kind: file.kind)
            }
            // The same text size and row height as a row in the Files panel.
            .font(.ui(size: Theme.TypeScale.meta))
            .frame(height: 16)
            // 6pt of this used to be row padding; now it's the inset outside the fill.
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .padding(.vertical, 3)
            .inspectorRow(isSelected: isSelected, isHovering: isHovering)
        }
        .buttonStyle(.pressable)
        .onHover { isHovering = $0 }
        .help(file.oldPath.map { "\($0) → \(file.path)" } ?? file.path)
    }
}

/// Another project Claude edited from this one, for the Changes panel.
struct OtherProjectChanges: Identifiable {
    let id: UUID
    let name: String
    let icon: AnyView
    /// How many of the files it edited there are still changed.
    let files: Int
    let lastEdit: Date
    let open: () -> Void
}

/// One project in Also Changed: its icon, name, and file count. Clicking
/// opens that project and its changes.
private struct OtherProjectRow: View {
    let other: OtherProjectChanges
    @State private var isHovering = false

    var body: some View {
        Button(action: other.open) {
            HStack(spacing: 6) {
                other.icon
                    .frame(width: 14, height: 14)
                Text(other.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                Text(other.files == 1 ? "1 file" : "\(other.files) files")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Image(systemName: "arrow.right")
                    .font(.ui(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .opacity(isHovering ? 1 : 0.5)
            }
            .font(.ui(size: Theme.TypeScale.meta))
            .frame(height: 16)
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .padding(.vertical, 3)
            .inspectorRow(isSelected: false, isHovering: isHovering)
        }
        .buttonStyle(.pressable)
        .onHover { isHovering = $0 }
        .help("Open \(other.name) to see its changes")
    }
}

/// A small icon button inside a file row.
private struct RowAction: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.ui(size: 10))
                .frame(width: 18, height: 16)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .fill(isHovering ? Theme.Fill.pressed : Theme.Fill.hover))
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct KindBadge: View {
    let kind: ChangeKind

    var body: some View {
        Text(letter)
            .font(.ui(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(kind.color)
            .frame(width: 14, height: 14)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(kind.color, lineWidth: 1))
            .help(label)
    }

    private var letter: String {
        switch kind {
        case .untracked: "U"
        case .conflicted: "!"
        default: kind.rawValue
        }
    }

    private var label: String {
        switch kind {
        case .modified: "Modified"
        case .added: "Added"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .copied: "Copied"
        case .untracked: "Untracked"
        case .conflicted: "Conflicted"
        case .typeChanged: "Type changed"
        }
    }
}

struct LineCounts: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: 4) {
            if additions > 0 { Text("+\(additions)").foregroundStyle(Theme.Status.done) }
            if deletions > 0 { Text("−\(deletions)").foregroundStyle(Theme.Status.failed) }
        }
        .font(.caption.monospacedDigit())
    }
}

private struct TotalsLabel: View {
    let files: [FileChange]

    var body: some View {
        LineCounts(
            additions: files.reduce(0) { $0 + $1.additions },
            deletions: files.reduce(0) { $0 + $1.deletions }
        )
    }
}

/// A commit row that can be clicked, lit on hover like a file row.
private struct CommitRowStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .background(Color.primary.opacity(configuration.isPressed ? 0.1 : isHovering ? 0.05 : 0))
            .onHover { isHovering = $0 }
    }
}

private struct CommitRow: View {
    let commit: Commit
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(commit.subject)
                .lineLimit(1)
                .truncationMode(.tail)
            HStack(spacing: 6) {
                Text(commit.shortHash).font(.caption.monospaced())
                Text(Self.relative(commit.date, now: now))
                    .font(.caption)
                Spacer(minLength: 0)
                LineCounts(additions: commit.additions, deletions: commit.deletions)
            }
            .foregroundStyle(.secondary)
        }
        .font(.ui(size: 11))
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(commit.body.isEmpty ? commit.subject : "\(commit.subject)\n\n\(commit.body)")
    }

    /// Compact relative time: "just now", "4m ago", "3h ago", "2d ago", then a date.
    static func relative(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(seconds / 60))m ago"
        case ..<86_400: return "\(Int(seconds / 3600))h ago"
        case ..<(86_400 * 7): return "\(Int(seconds / 86_400))d ago"
        default: return date.formatted(.dateTime.month(.abbreviated).day())
        }
    }
}

/// The base's name, with a menu of branches to compare against when the
/// caller can change it.
private struct BasePicker: View {
    let current: String?
    var shortName: String? = nil
    let chosen: String?
    let branches: [String]
    let choose: ((String?) -> Void)?

    var body: some View {
        if let choose {
            Menu {
                Button {
                    choose(nil)
                } label: {
                    if chosen == nil { Label("Default branch", systemImage: "checkmark") } else { Text("Default branch") }
                }
                Divider()
                ForEach(branches.prefix(40), id: \.self) { branch in
                    Button {
                        choose(branch)
                    } label: {
                        if chosen == branch { Label(branch, systemImage: "checkmark") } else { Text(branch) }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    label
                    Image(systemName: "chevron.down")
                        .font(.ui(size: 7.5, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            // Line the name up with the row's label; the menu otherwise
            // sits a point low.
            .alignmentGuide(.firstTextBaseline) { $0[.firstTextBaseline] + 1 }
            .help("Comparing against \(current ?? "the default branch"). Click to change.")
        } else {
            label
                .help("Comparing against \(current ?? "the default branch")")
        }
    }

    private var label: some View {
        Text(shortName ?? current ?? "base")
            .fontWeight(.medium)
            .lineLimit(1)
    }
}

#if DEBUG
/// The Changes list drawn to PNGs in light and dark, from sample data with
/// and without the header details an older Mac leaves out.
/// BENCH_RENDER_CHANGES=<folder>.
enum ChangesListPreview {
    static func render(to folder: URL) {
        _ = NSApplication.shared
        let file = { (path: String, kind: ChangeKind, add: Int, del: Int) in
            FileChange(path: path, kind: kind, additions: add, deletions: del, section: .unstaged)
        }
        var full = ChangesSnapshot(
            branch: "sim-realism", baseRef: "origin/main",
            unstaged: [file("src/sim/race.ts", .modified, 2, 1), file("src/sim/raceControl.test.ts", .modified, 9, 0)],
            againstBase: [file("docs/plans/2026-11-02-sim-realism.md", .added, 146, 0), file("scripts/realism.ts", .added, 163, 0),
                          file("src/sim/incidents.ts", .modified, 2, 2), file("src/sim/offs.ts", .modified, 17, 9)],
            commits: [Commit(hash: "abc1234def", shortHash: "abc1234", subject: "Race control rules", body: "", author: "", date: .now.addingTimeInterval(-3600))],
            aheadOfBase: 5, behindBase: 0, forkedAt: .now.addingTimeInterval(-2 * 86_400), upstream: nil,
            lastFetch: .now.addingTimeInterval(-32 * 60), branches: ["main", "origin/main"], chosenBase: nil)
        draw(full, name: "changes-full", folder: folder)
        full.upstream = "origin/sim-realism"; full.unpushed = 2; full.unpulled = 0
        draw(full, name: "changes-pushed", folder: folder)
        let old = ChangesSnapshot(branch: full.branch, baseRef: full.baseRef, unstaged: full.unstaged,
                                  againstBase: full.againstBase, commits: full.commits)
        draw(old, name: "changes-older-mac", folder: folder)
    }

    private static func draw(_ snapshot: ChangesSnapshot, name: String, folder: URL) {
        var view = ChangesList(snapshot: snapshot, openDiff: { _ in }, refresh: {}, chooseBase: { _ in }) { _ in EmptyView() }
        view.actions = ClaudeAction.defaults + [ClaudeAction(name: "Pull", prompt: "Pull", symbol: "arrow.down.circle"),
                                                ClaudeAction(name: "Make merge", prompt: "Merge")]
        view.runAction = { _ in nil }
        for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let host = NSHostingView(rootView: view.frame(width: 300, height: 520).background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 520), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            host.setFrameSize(NSSize(width: 300, height: 520))
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("\(name)-\(mode).png"))
        }
    }
}
#endif
