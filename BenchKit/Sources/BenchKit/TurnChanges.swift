import Foundation

/// The files one turn changed: everything Claude edited or wrote between
/// one of your prompts and the next, so a finished reply can be read as
/// one change.
///
/// It's put together from the edits in the transcript, which is all there
/// is to go on without snapshots of the folder. So it knows what Claude's
/// own Edit and Write calls did, and nothing about files a shell command
/// or a subagent changed; `ranShell` and `ranAgents` say when that could
/// matter, and `incompleteNote` words it.
public struct TurnChanges: Equatable, Identifiable, Sendable {
    /// One file the turn touched, with every edit to it folded together.
    public struct File: Equatable, Identifiable, Sendable {
        /// Its full path.
        public var path: String
        /// True for a file the turn made.
        public var isNewFile: Bool
        /// Lines added and removed, summed over the turn's edits to it. An
        /// edit that undoes an earlier one still counts twice: these are
        /// what the edits did, not the difference from start to finish.
        public var additions: Int
        public var deletions: Int
        /// False when the transcript doesn't say what changed, as for a notebook.
        public var hasCounts: Bool
        /// How many edits were made to it.
        public var edits: Int
        /// Each edit's changed stretches, in the order they were made.
        /// Line numbers are the file's as it was at that edit; a start of
        /// zero on both sides means they aren't known.
        public var hunks: [EditPatch.Hunk]
        /// Some of the change isn't in `hunks`: it was too long to keep,
        /// or the transcript only had its first lines.
        public var truncated: Bool

        public var id: String { path }
        public var fileName: String { (path as NSString).lastPathComponent }
    }

    /// The message that started the turn, by its id in the transcript. A
    /// conversation read from part-way through starts with a turn named
    /// for its first row.
    public var id: String
    /// What you asked for, on one line.
    public var prompt: String?
    /// The last row of the turn, which the list of changes goes under.
    public var lastRowID: String
    /// The files, in the order the turn first touched them.
    public var files: [File] = []
    /// The turn ran a shell command that isn't plainly a read.
    public var ranShell = false
    /// The turn started subagents, whose edits are kept elsewhere.
    public var ranAgents = false
    /// True for the newest turn, which may still be under way.
    public var isLatest = false

    public var additions: Int { files.reduce(0) { $0 + $1.additions } }
    public var deletions: Int { files.reduce(0) { $0 + $1.deletions } }

    /// Why the list may not be everything the turn changed, or nil when
    /// nothing in the turn could have changed a file unseen.
    public var incompleteNote: String? {
        switch (ranShell, ranAgents) {
        case (true, true): "Shell commands and subagents in this turn may have changed other files."
        case (true, false): "Shell commands in this turn may have changed other files."
        case (false, true): "Subagents in this turn may have changed other files."
        case (false, false): nil
        }
    }

    // MARK: - From a conversation

    /// The turns that changed files, oldest first.
    public static func all(in turns: [TranscriptTurn]) -> [TurnChanges] {
        every(in: turns).filter { !$0.files.isEmpty }
    }

    /// The newest turn, whether or not it changed anything. Nil for a
    /// conversation with nothing in it.
    public static func latest(in turns: [TranscriptTurn]) -> TurnChanges? {
        every(in: turns).last
    }

    /// One turn by the row of its prompt.
    public static func turn(_ id: String, in turns: [TranscriptTurn]) -> TurnChanges? {
        every(in: turns).first { $0.id == id }
    }

    private static func every(in turns: [TranscriptTurn]) -> [TurnChanges] {
        var result: [TurnChanges] = []
        var current: TurnChanges?
        var order: [String] = []
        var files: [String: File] = [:]

        func close() {
            guard var turn = current else { return }
            turn.files = order.compactMap { files[$0] }
            result.append(turn)
            current = nil
            order = []
            files = [:]
        }
        func touch(_ path: String, _ change: (inout File) -> Void) {
            let path = path.hasPrefix("/") ? (path as NSString).standardizingPath : path
            if files[path] == nil {
                order.append(path)
                files[path] = File(path: path, isNewFile: false, additions: 0, deletions: 0, hasCounts: true, edits: 0, hunks: [], truncated: false)
            }
            files[path]!.edits += 1
            change(&files[path]!)
        }

        for row in turns where !row.isQueued {
            if case .user(let message) = row.kind, message.shell == nil, message.command == nil {
                close()
                // The message's own id, not the row's: a row can keep the id
                // of the bubble shown while the message was on its way.
                current = TurnChanges(id: message.id, lastRowID: row.id)
                let asked = ToolWording.oneLine(message.text)
                current?.prompt = asked.isEmpty ? nil : String(asked.prefix(200))
                continue
            }
            if current == nil { current = TurnChanges(id: "before-" + row.id, lastRowID: row.id) }
            current?.lastRowID = row.id
            guard case .steps(let steps) = row.kind else { continue }
            for step in steps {
                let result = step.toolUseID.flatMap { row.results[$0] }
                if step.agent != nil { current?.ranAgents = true }
                // An edit that failed, or that you said no to, changed nothing.
                let failed = result?.isError == true
                if let patch = result?.patch, !failed {
                    guard !PlanText.isPlanFile(patch.path) else { continue }
                    touch(patch.path) { file in
                        if patch.isNewFile, file.edits == 1 { file.isNewFile = true }
                        file.additions += patch.additions
                        file.deletions += patch.deletions
                        file.hunks += patch.hunks
                        if patch.truncated { file.truncated = true }
                    }
                } else if step.tool == .notebookEdit {
                    guard !failed, let path = step.detail else { continue }
                    touch(path) { file in
                        if file.edits == 1 { file.hasCounts = false }
                    }
                } else if let edit = step.edit, let path = step.detail {
                    // No patch on the result: an older reader, or a file
                    // written from the shell. The call itself says how
                    // much changed, and shows its first lines.
                    guard !failed, !PlanText.isPlanFile(path) else { continue }
                    touch(path) { file in
                        if edit.isNewFile, file.edits == 1 { file.isNewFile = true }
                        file.additions += edit.addedCount
                        file.deletions += edit.removedCount
                        let lines = edit.removed.map { "-" + $0 } + edit.added.map { "+" + $0 }
                        if !lines.isEmpty { file.hunks.append(EditPatch.Hunk(oldStart: 0, newStart: 0, lines: lines)) }
                        if edit.removedCount > edit.removed.count || edit.addedCount > edit.added.count { file.truncated = true }
                    }
                } else if step.tool == .shell {
                    // Anything that isn't plainly a look at some files
                    // could have written one.
                    if step.detail.map({ ShellStep.read($0) == nil }) ?? true { current?.ranShell = true }
                }
            }
        }
        close()
        if !result.isEmpty { result[result.count - 1].isLatest = true }
        return result
    }

    // MARK: - Paths

    /// A file's path as it's shown: its place in the project when it's in
    /// the project, and otherwise the whole path, with `~` for your home.
    public static func shownPath(_ path: String, root: String?) -> String {
        if let root, !root.isEmpty {
            // Both tidied the same way, so /private/tmp and /tmp are one place.
            let folder = (root as NSString).standardizingPath
            let file = (path as NSString).standardizingPath
            let prefix = folder.hasSuffix("/") ? folder : folder + "/"
            if file.hasPrefix(prefix) { return String(file.dropFirst(prefix.count)) }
        }
        return (path as NSString).abbreviatingWithTildeInPath
    }
}

public extension ReviewDiff {
    /// A turn's changes as a review: each file's edits one after another
    /// under its header, like the files of a commit.
    init(turn: TurnChanges, root: String?) {
        self.init()
        for changed in turn.files {
            var file = ReviewFile(path: TurnChanges.shownPath(changed.path, root: root), status: changed.isNewFile ? "A" : "M")
            file.additions = changed.additions
            file.deletions = changed.deletions
            file.headerLine = lines.count
            lines.append(DiffLine(id: lines.count, kind: .hunk, text: Self.headerText(file), oldNumber: nil, newNumber: nil))
            var body: [DiffLine] = []
            func add(_ kind: DiffLine.Kind, _ text: String, old: Int? = nil, new: Int? = nil) {
                body.append(DiffLine(id: lines.count + body.count, kind: kind, text: text, oldNumber: old, newNumber: new))
            }
            for (index, hunk) in changed.hunks.enumerated() {
                // A gap between one changed stretch and the next.
                if index > 0 { add(.hunk, "") }
                let numbered = hunk.oldStart > 0 || hunk.newStart > 0
                var old = hunk.oldStart, new = hunk.newStart
                for line in hunk.lines {
                    let text = String(line.dropFirst())
                    switch line.first {
                    case "+":
                        add(.added, text, new: numbered ? new : nil)
                        new += 1
                    case "-":
                        add(.removed, text, old: numbered ? old : nil)
                        old += 1
                    case "\\":
                        add(.meta, line)
                    default:
                        add(.context, text, old: numbered ? old : nil, new: numbered ? new : nil)
                        old += 1
                        new += 1
                    }
                }
            }
            if !changed.hasCounts {
                add(.meta, "The conversation doesn't record what changed in this file.")
            } else if changed.truncated {
                add(.meta, "The rest of this change is too long to show here.")
            }
            WordDiff.annotate(&body)
            lines += body
            files.append(file)
        }
    }
}
