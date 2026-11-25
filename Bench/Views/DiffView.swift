import BenchKit
import SwiftUI

/// Shows one file's diff over the terminal area.
struct DiffView: View {
    @Environment(AppStore.self) private var store
    @Environment(ReviewComments.self) private var reviews
    @Environment(TerminalManager.self) private var terminals
    let project: Project
    let monitor: RepoMonitor
    let change: FileChange
    /// The tab it's in, so the File switch can turn it into the file view.
    var tabID: UUID?
    /// Whether this tab has the keys, for the next-change shortcuts.
    var isFocused = true

    /// Every line of the diff, with the whole file as context.
    @State private var allLines: [DiffLine]?
    /// What's shown: `allLines` with long unchanged stretches folded.
    @State private var lines: [DiffLine]?
    @State private var layout: DiffLayout?
    /// Fold rows in `lines`, by index, with their keys.
    @State private var folds: [Int: Int] = [:]
    /// Folds the user opened.
    @State private var expanded: Set<Int> = []
    @State private var jump = ChangeJump()
    @State private var images: ImagePair?
    /// The line being commented on, by its index in `lines`.
    @State private var composingLine: Int?
    @State private var draft = ""
    @AppStorage("fileViewWraps") private var wraps = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(TerminalTheme.shared.canvas)
        .task(id: TaskKey(change: change, refresh: monitor.lastRefresh)) { await load() }
    }

    private struct TaskKey: Equatable {
        var change: FileChange
        var refresh: Date?
    }

    /// The latest version of this file's entry, so counts stay live while it changes.
    private var current: FileChange {
        guard let snapshot = monitor.snapshot else { return change }
        let all = snapshot.staged + snapshot.unstaged + snapshot.againstBase
        return all.first { $0.id == change.id } ?? change
    }

    /// The buttons keep the order the file's header uses (`FileHeader`), so
    /// nothing moves when a tab flips between File and Changes.
    private var header: some View {
        let change = current
        return PaneHeader(title: change.fileName, subtitle: change.directory, badge: sectionLabel) {
            reviewControls
            if !change.isImage {
                ChangeStepButtons(hasKeys: isFocused) { forward in
                    jump = ChangeJump(id: jump.id + 1, forward: forward)
                }
            }
            // A deleted file has nothing on disk to show.
            if change.kind != .deleted {
                ChangesFileSwitch(mode: .changes) { _ in
                    if let tabID {
                        store.showFile(change.path, inTab: tabID, of: project.id)
                    } else {
                        store.openFile(change.path, in: project.id)
                    }
                }
            }
            if !change.isImage {
                Text("+\(change.additions)").foregroundStyle(Theme.Status.done).font(.callout.monospacedDigit())
                Text("−\(change.deletions)").foregroundStyle(Theme.Status.failed).font(.callout.monospacedDigit())
            }
            if !change.isImage {
                Toggle(isOn: $wraps) {
                    Image(systemName: "text.word.spacing")
                }
                .toggleStyle(.button)
                .buttonStyle(.borderless)
                .help(wraps ? "Stop wrapping long lines" : "Wrap long lines")
            }
            // The file as it is now, not the diff. A deleted file has none.
            if !change.isImage, change.kind != .deleted {
                CopyFileButton {
                    if case .text(let text) = FileReader.read(project.url.appendingPathComponent(change.path)) { return text }
                    return nil
                }
            }
            // A deleted file has nothing in Finder to show either.
            if change.kind != .deleted {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([project.url.appendingPathComponent(change.path)])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
            }
            Button {
                NSWorkspace.shared.open(project.url.appendingPathComponent(change.path))
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.borderless)
            .help("Open in default app")
        }
    }

    private var agentName: String { terminals.agentName(in: project) }

    /// Asks first: the comments are the whole review, and they can't be
    /// brought back.
    private func confirmDiscard(_ count: Int) {
        let alert = NSAlert()
        alert.messageText = count == 1 ? "Discard 1 comment?" : "Discard \(count) comments?"
        alert.informativeText = count == 1 ? "It's deleted without being sent to \(agentName)." : "They're deleted without being sent to \(agentName)."
        alert.addButton(withTitle: "Discard").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        reviews.clear(project.id)
    }

    /// Shown once there's at least one comment anywhere in the project.
    @ViewBuilder
    private var reviewControls: some View {
        let comments = reviews.comments(for: project.id)
        if !comments.isEmpty {
            Button("Discard Comments…", role: .destructive) { confirmDiscard(comments.count) }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(comments.count == 1 ? "Delete the comment without sending it" : "Delete all \(comments.count) comments without sending them")
            Button {
                terminals.sendToClaude(ReviewComments.prompt(for: comments), in: project)
                reviews.clear(project.id)
            } label: {
                Label(comments.count == 1 ? "Send Comment to \(agentName)" : "Send \(comments.count) Comments to \(agentName)",
                      systemImage: "paperplane.fill")
            }
            .buttonStyle(.prominent)
            .controlSize(.small)
            // The subtitle beside it gives way first; a fixed size here
            // would ask the inspector for more width than it may have.
            .layoutPriority(1)
            .help("Types your comments into \(agentName). Press Return there to send.")
        }
    }

    private var fileComments: [DiffComment] {
        reviews.comments(for: project.id).filter { $0.path == change.path }
    }

    /// Comments whose line is no longer in the diff, e.g. after Claude edited it.
    private var orphanedComments: [DiffComment] {
        guard let allLines else { return [] }
        return fileComments.filter { comment in !allLines.contains { comment.belongs(to: $0) } }
    }

    /// Comments on lines still in the diff, in the diff's order, each with
    /// the index of its line.
    private var attachedComments: [(line: Int, comment: DiffComment)] {
        guard let lines else { return [] }
        return fileComments.compactMap { comment in
            lines.firstIndex { comment.belongs(to: $0) }.map { (line: $0, comment: comment) }
        }
        .sorted { $0.line < $1.line }
    }

    @ViewBuilder
    private var content: some View {
        if change.isImage {
            if let images {
                ImageDiffView(images: images)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if let lines, let layout {
            if lines.isEmpty {
                ContentUnavailableView("No Differences", systemImage: "equal",
                                       description: Text("This file has no text changes to show."))
            } else {
                VStack(spacing: 0) {
                    DiffTextView(layout: layout, path: change.path,
                                 segments: lines.map(\.segments),
                                 oldNumbers: lines.map(\.oldNumber),
                                 newNumbers: lines.map(\.newNumber),
                                 wraps: wraps,
                                 commentedLines: Set(attachedComments.map(\.line)),
                                 composing: composingLine,
                                 folds: Set(folds.keys),
                                 onFold: { index in
                                     guard let key = folds[index] else { return }
                                     expanded.insert(key)
                                     refold()
                                 },
                                 jump: jump,
                                 onRunOut: runOut) { index in
                        composingLine = index
                        draft = ""
                    }
                    commentList(lines: lines)
                }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The comment being written and the saved ones, under the text. They
    /// sit outside the text's scroll view, so the editor is in view no
    /// matter how far down the line is.
    @ViewBuilder
    private func commentList(lines: [DiffLine]) -> some View {
        let attached = attachedComments
        let orphans = orphanedComments
        let composing = composingLine.flatMap { lines.indices.contains($0) ? lines[$0] : nil }
        if composing != nil || !attached.isEmpty || !orphans.isEmpty {
            Divider()
            let list = VStack(alignment: .leading, spacing: 0) {
                if let composing {
                    CommentEditor(line: composing, text: $draft) {
                        composingLine = nil
                    } save: {
                        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !body.isEmpty {
                            reviews.add(DiffComment(path: change.path, line: composing, body: body), to: project.id)
                            // A comment is worth keeping the tab for.
                            store.keepDiff(change.id, in: project.id)
                            Analytics.capture(.diffCommentAdded)
                        }
                        composingLine = nil
                    }
                }
                ForEach(attached, id: \.comment.id) { item in
                    CommentCard(comment: item.comment, showsLocation: true) { reviews.remove(item.comment.id, from: project.id) }
                }
                if !orphans.isEmpty {
                    Text("Comments on lines that have since changed")
                        .font(.ui(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                        .padding(.bottom, 2)
                    ForEach(orphans) { comment in
                        CommentCard(comment: comment, showsLocation: true) { reviews.remove(comment.id, from: project.id) }
                    }
                }
            }
            .padding(.vertical, 6)
            // A few comments take the room they need; more than that
            // scroll in a fixed strip, so the diff keeps most of the pane.
            if attached.count + orphans.count > 3 {
                ScrollView { list }.frame(height: 240)
            } else {
                list
            }
        }
    }

    private var sectionLabel: String {
        switch change.section {
        case .staged: "Staged"
        case .unstaged: change.kind == .untracked ? "Untracked" : "Unstaged"
        case .againstBase: "vs \(monitor.snapshot?.baseRef ?? "base")"
        }
    }

    private func load() async {
        if change.isImage {
            let (old, new) = await monitor.client.versions(for: change, baseRef: monitor.snapshot?.baseRef)
            let pair = ImagePair(old: old, new: new)
            if pair != images { images = pair }
            return
        }
        let text = await monitor.client.diff(for: change, baseRef: monitor.snapshot?.baseRef, wholeFile: true)
        let parsed = await Task.detached { DiffParser.parse(text) }.value
        if parsed != allLines {
            allLines = parsed
            refold()
        }
    }

    /// Folds `allLines` again after it changed or a fold was opened. Folds
    /// hiding a commented line stay open, so the comment has its line.
    private func refold() {
        guard let allLines else { return }
        let commented = allLines.filter { line in fileComments.contains { $0.belongs(to: line) } }
        expanded.formUnion(DiffFolding.keys(hiding: commented, in: allLines))
        let result = DiffFolding.fold(allLines, expanded: expanded)
        let composed = composingLine.flatMap { lines?.indices.contains($0) == true ? lines?[$0].id : nil }
        lines = result.lines
        layout = DiffLayout(lines: result.lines)
        folds = result.folds
        // The line being commented on may have moved when a fold opened.
        composingLine = composed.flatMap { id in result.lines.firstIndex { $0.id == id } }
    }

    /// Past the last change, on to the next changed file (or back to the
    /// previous one) in the same list, in this same tab.
    private func runOut(_ forward: Bool) {
        guard let tabID, let snapshot = monitor.snapshot else { return }
        let files = snapshot.filesInOrder(section: change.section).filter { !$0.isImage }
        guard let index = files.firstIndex(where: { $0.id == change.id }) else { return }
        let next = forward ? index + 1 : index - 1
        guard files.indices.contains(next) else { return }
        store.showChanges(files[next], inTab: tabID, of: project.id)
    }
}

/// A saved comment, shown under its line.
private struct CommentCard: View {
    let comment: DiffComment
    var showsLocation = false
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "text.bubble.fill")
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                if showsLocation {
                    Text(comment.location)
                        .font(.ui(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text(comment.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(action: delete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Delete comment")
        }
        .font(.ui(size: 12))
        .commentBox()
    }
}

/// The box for writing a new comment, headed by the line it's about.
private struct CommentEditor: View {
    let line: DiffLine
    @Binding var text: String
    let cancel: () -> Void
    let save: () -> Void
    @FocusState private var focused: Bool

    private var lineLabel: String {
        if let new = line.newNumber { return "Line \(new)" }
        if let old = line.oldNumber { return "Removed line \(old)" }
        return "This line"
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 6) {
                Text(lineLabel)
                    .font(.ui(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(line.text.trimmingCharacters(in: .whitespaces))
                    .font(.ui(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            TextEditor(text: $text)
                .font(.ui(size: 12))
                .scrollContentBackground(.hidden)
                .focused($focused)
                .frame(minHeight: 44, maxHeight: 120)
                .fixedSize(horizontal: false, vertical: true)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("What should change here?")
                            .font(.ui(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
            HStack {
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Add Comment", action: save)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.prominent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.small)
        }
        .commentBox()
        .onAppear { focused = true }
    }
}

private extension View {
    func commentBox() -> some View {
        padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12))
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
    }
}
