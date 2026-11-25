import BenchKit
import SwiftUI

/// A commit, the whole branch, or one turn of a Claude tab on one page:
/// what it says, the files it touched down the side, and every file's diff
/// stacked in one scrolling text.
struct ReviewView: View {
    let project: Project
    let monitor: RepoMonitor
    let target: ReviewTarget
    /// The tab this is in, where it's in one: lets the page switch between
    /// the latest turn and the branch, and be scrolled to a file.
    var tabID: UUID?

    // Optional, so the page can be drawn on its own for a preview.
    @Environment(AppStore.self) private var store: AppStore?
    @Environment(TerminalManager.self) private var terminals: TerminalManager?

    @State private var commit: Commit?
    /// For a turn's review: the turn, once read.
    @State private var turn: TurnChanges?
    /// For a turn's review: why there's nothing to show, if there isn't.
    @State private var turnProblem: TurnReview.Loaded?
    /// The last request to scroll to a file that was carried out.
    @State private var revealed = 0
    @State private var diff: ReviewDiff?
    @State private var layout: DiffLayout?
    /// The file whose lines are at the top of the text, for the side list.
    @State private var currentFile: String?
    @State private var reveal = LineReveal()
    @AppStorage("fileViewWraps") private var wraps = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let turnProblem {
                EmptyStateScaffold(title: turnProblem == .turnGone ? "Turn Not Found" : "No Conversation",
                                   message: turnProblem == .turnGone
                                       ? "This turn isn't in the recent part of the conversation any more."
                                       : "This tab has no conversation to read yet.") {
                    DiffEmptyIllustration(appeared: $0)
                }
                .environment(\.companionPalette, TerminalTheme.shared.chatPalette)
            } else if let diff, let layout {
                if diff.files.isEmpty {
                    EmptyStateScaffold(title: target.turn == nil ? "No Changes" : "No File Edits", message: emptyMessage) {
                        DiffEmptyIllustration(appeared: $0, command: target.commit == nil ? "git diff --stat" : "git show --stat")
                    }
                    .environment(\.companionPalette, TerminalTheme.shared.chatPalette)
                } else {
                    HStack(spacing: 0) {
                        fileList(diff)
                            .frame(width: 220)
                        Divider()
                        DiffTextView(layout: layout, segments: diff.lines.map(\.segments),
                                     oldNumbers: diff.lines.map(\.oldNumber), newNumbers: diff.lines.map(\.newNumber),
                                     wraps: wraps, commentedLines: [], composing: nil,
                                     headers: Set(diff.files.map(\.headerLine)),
                                     sections: diff.files.indices.map {
                                         SyntaxColors.Section(lines: diff.lineRange(ofFileAt: $0), path: diff.files[$0].path)
                                     },
                                     reveal: reveal,
                                     onTopLine: { line in
                                         let file = diff.files.last { $0.headerLine <= line }?.path
                                         if file != currentFile { currentFile = file }
                                     },
                                     onComment: { _ in })
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(TerminalTheme.shared.canvas)
        .task(id: LoadKey(target: target, refresh: target.commit == nil && target.turn == nil ? monitor.lastRefresh : nil)) {
            if let turn = target.turn { await follow(turn) } else { await load() }
        }
        .onChange(of: target) { old, new in
            // The same tab, pointed at something else: start clean.
            guard old.turn != new.turn || old.commit != new.commit else { return }
            commit = nil
            turn = nil
            turnProblem = nil
            diff = nil
            layout = nil
            currentFile = nil
        }
        .onChange(of: store?.reviewReveal) { _, _ in revealRequestedFile() }
    }

    private var emptyMessage: String {
        if target.turn != nil {
            let none = turn?.isLatest == false ? "The agent didn't edit any files in this turn." : "The agent didn't edit any files in its latest turn."
            return [none, turn?.incompleteNote].compactMap { $0 }.joined(separator: " ")
        }
        return target.commit == nil ? "This branch has no commits of its own yet." : "This commit doesn't change any files."
    }

    private struct LoadKey: Equatable {
        var target: ReviewTarget
        var refresh: Date?
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(commit?.subject ?? turn?.prompt ?? target.title)
                    .font(Theme.TypeScale.font(Theme.TypeScale.ui + 2, weight: .semibold))
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                sourceSwitch
                Toggle(isOn: $wraps) {
                    Image(systemName: "text.word.spacing")
                }
                .toggleStyle(.button)
                .buttonStyle(.borderless)
                .help(wraps ? "Stop wrapping long lines" : "Wrap long lines")
            }
            if let body = commit?.body, !body.isEmpty {
                ScrollView {
                    Text(body)
                        .font(Theme.TypeScale.font(Theme.TypeScale.bodySmall))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 120)
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                if let commit {
                    Text(commit.shortHash).font(.caption.monospaced())
                    Text("\(commit.author) · \(commit.date.formatted(.relative(presentation: .named)))")
                    Button("Copy Hash") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(commit.hash, forType: .string)
                    }
                    .buttonStyle(.link)
                } else if target.turn != nil {
                    if let turn {
                        Text(turn.isLatest ? "What the agent's edits changed in its latest turn" : "What the agent's edits changed in an earlier turn")
                        if !turn.isLatest, target.turn?.turnID != nil {
                            Button("Show Latest") { showLatestTurn() }
                                .buttonStyle(.link)
                        }
                    }
                } else if target.commit == nil {
                    Text("Everything on this branch since it left \(monitor.snapshot?.baseRef ?? "its base")")
                }
                if let diff {
                    Text(diff.files.count == 1 ? "1 file" : "\(diff.files.count) files")
                    LineCounts(additions: diff.files.reduce(0) { $0 + $1.additions },
                               deletions: diff.files.reduce(0) { $0 + $1.deletions })
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if target.turn != nil, let note = turn?.incompleteNote, diff?.files.isEmpty == false {
                // Only Claude's own edits are in the conversation to read.
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Latest turn or branch

    private enum Source: Hashable { case turn, branch }

    /// Switches the page between the latest turn and the whole branch.
    /// Only for those two, in a tab, in a project with a Claude tab to
    /// have turns.
    @ViewBuilder private var sourceSwitch: some View {
        if target.commit == nil, tabID != nil, store != nil,
           target.turn != nil || project.tabs.contains(where: { $0.kind == .agent }) {
            Picker("Show", selection: Binding(get: { target.turn == nil ? Source.branch : .turn }, set: { show($0) })) {
                Text("Latest Turn").tag(Source.turn)
                Text("Branch").tag(Source.branch)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .help("Show what the agent's latest turn changed, or everything on this branch")
        }
    }

    private func show(_ source: Source) {
        guard let store, let tabID else { return }
        switch source {
        case .branch:
            guard target.turn != nil else { return }
            store.showReview(.branch(monitor.snapshot?.branch), inTab: tabID, of: project.id)
        case .turn:
            guard target.turn == nil else { return }
            showLatestTurn()
        }
    }

    private func showLatestTurn() {
        guard let store, let tabID else { return }
        let claudeTab = target.turn?.tabID ?? terminals.flatMap { TurnReview.latestClaudeTab(in: store.project(project.id) ?? project, terminals: $0) }
        guard let claudeTab else { return }
        store.showReview(.turn(nil, inTab: claudeTab), inTab: tabID, of: project.id)
    }

    // MARK: Files

    private func fileList(_ diff: ReviewDiff) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(diff.files) { file in
                    Button {
                        currentFile = file.path
                        reveal = LineReveal(id: reveal.id + 1, line: file.headerLine)
                    } label: {
                        HStack(spacing: 6) {
                            Text(file.status)
                                .font(.ui(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(Self.statusColor(file.status))
                                .frame(width: 12)
                            Text(file.fileName)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            LineCounts(additions: file.additions, deletions: file.deletions)
                        }
                        .font(.ui(size: 11))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(currentFile == file.path ? Color.primary.opacity(0.09) : .clear))
                    }
                    .buttonStyle(.pressable)
                    .help(file.path)
                }
            }
            .padding(6)
        }
    }

    private static func statusColor(_ status: String) -> Color {
        switch status {
        case "A": Theme.Status.done
        case "D": Theme.Status.failed
        case "R": .blue
        default: .orange
        }
    }

    // MARK: Loading

    /// Reads the turn from the tab's transcript, and again whenever the
    /// transcript grows, so the latest turn follows along.
    private func follow(_ wanted: ReviewTarget.Turn) async {
        var seen: (path: String?, size: UInt64?)?
        let root = project.path
        while !Task.isCancelled {
            let path = terminals.flatMap { CompanionSnapshots.transcriptPath(tabID: wanted.tabID, terminals: $0) }
                ?? AgentSessions.transcriptPath(tabID: wanted.tabID)
            let size = TurnReview.size(of: path)
            if seen == nil || seen?.path != path || seen?.size != size {
                seen = (path, size)
                let loaded = await Task.detached { TurnReview.load(path: path, turnID: wanted.turnID, root: root) }.value
                guard !Task.isCancelled else { return }
                show(loaded)
            }
            try? await Task.sleep(for: .seconds(1.5))
        }
    }

    private func show(_ loaded: TurnReview.Loaded) {
        guard case .turn(let found, let next) = loaded else {
            if turnProblem != loaded { turnProblem = loaded }
            return
        }
        turnProblem = nil
        if turn != found { turn = found }
        if next != diff {
            diff = next
            layout = DiffLayout(lines: next.lines)
            if currentFile == nil || !next.files.contains(where: { $0.path == currentFile }) { currentFile = next.files.first?.path }
        }
        revealRequestedFile()
    }

    /// Scrolls to the file a click asked for, once its lines are here.
    private func revealRequestedFile() {
        guard let request = store?.reviewReveal, request.tabID == tabID, request.id != revealed, let diff else { return }
        let shown = TurnChanges.shownPath(request.path, root: project.path)
        guard let file = diff.files.first(where: { $0.path == shown }) else { return }
        revealed = request.id
        currentFile = file.path
        reveal = LineReveal(id: reveal.id + 1, line: file.headerLine)
    }

    private func load() async {
        let client = monitor.client
        if let hash = target.commit, commit?.hash != hash {
            commit = await client.commit(hash)
        }
        let text = await client.reviewDiff(commit: target.commit, baseRef: monitor.snapshot?.baseRef)
        let next = await Task.detached { ReviewDiff(parsing: text) }.value
        guard next != diff else { return }
        diff = next
        layout = DiffLayout(lines: next.lines)
        if currentFile == nil { currentFile = next.files.first?.path }
    }
}

/// A request to scroll a line to the top. A new id each time, so asking
/// for the same line twice scrolls twice.
struct LineReveal: Equatable {
    var id = 0
    var line = 0
}

#if DEBUG
/// The review page for a repository's latest commit, drawn to PNGs in
/// light and dark. BENCH_RENDER_REVIEW=<folder>, BENCH_RENDER_REVIEW_REPO=<repo>.
enum ReviewPreview {
    static func render(to folder: URL, repo: String) {
        _ = NSApplication.shared
        let project = Project(path: repo)
        let monitor = RepoMonitor(project: project)
        for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let size = NSSize(width: 1100, height: 760)
            let host = NSHostingView(rootView: ReviewView(project: project, monitor: monitor, target: ReviewTarget(commit: "HEAD", title: "HEAD"))
                .frame(width: size.width, height: size.height))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            host.setFrameSize(size)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(4))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("review-\(mode).png"))
        }
    }
}
#endif
