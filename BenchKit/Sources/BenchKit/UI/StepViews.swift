import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension EnvironmentValues {
    /// Opens a file Claude touched, by its full path. Set where there's
    /// somewhere to open it.
    @Entry public var openStepFile: ((String) -> Void)?
    /// Shows the file a piece of inline code names, in the Finder, and says
    /// whether it did. Set where there's a Finder; elsewhere a click on
    /// code copies it. See `LocalFilePath` for what counts as a file.
    @Entry public var revealStepFile: ((String) -> Bool)?
    /// Reads a picture whole, for a chat that holds previews and has no
    /// Mac to ask: the Mac's own chat reads it back from the transcript.
    @Entry public var loadFullImage: (@Sendable (TranscriptImage) async -> TranscriptImage?)?
    /// The type sizes for steps.
    @Entry public var stepFonts = StepFonts.phone
    /// The type for Markdown's blocks: headings, code, and tables.
    @Entry public var markdownFonts = MarkdownFonts.standard
    /// True to fold an edit's lines away until tapped, for small screens.
    @Entry public var collapsesDiffs = false
    /// The other project a file Claude edited is in, by its full path, or
    /// nil when it's in the conversation's own project (or none).
    @Entry public var stepFileProject: ((String) -> StepFileProject?)?
}

/// Another project a step's file belongs to, for the chip on its card.
public struct StepFileProject {
    public var name: String
    public var icon: AnyView
    /// Opens that project, where that's possible.
    public var open: (() -> Void)?

    public init(name: String, icon: AnyView, open: (() -> Void)? = nil) {
        self.name = name
        self.icon = icon
        self.open = open
    }
}

/// Marks an edit made in another project: its icon and name, in a capsule.
struct StepProjectChip: View {
    @Environment(\.companionPalette) private var palette
    @Environment(\.stepFonts) private var fonts
    let project: StepFileProject

    var body: some View {
        let label = HStack(spacing: 4) {
            project.icon
                .frame(width: 13 * fonts.scale, height: 13 * fonts.scale)
            Text(project.name)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(fonts.text.weight(.medium))
        .foregroundStyle(palette.ink.opacity(0.85))
        .padding(.leading, 3)
        .padding(.trailing, 7)
        .padding(.vertical, 2)
        .background(palette.ink.opacity(0.07), in: Capsule())
        .overlay(Capsule().strokeBorder(palette.hairline))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("In \(project.name)")
        if let open = project.open {
            Button(action: open) { label }
                .buttonStyle(.pressable)
                .help("This file is in \(project.name). Click to open that project.")
        } else {
            label.help("This file is in \(project.name)")
        }
    }
}

/// The type for steps: the Mac's chat sets its own sizes, the phone
/// follows Dynamic Type.
public struct StepFonts: Sendable {
    public var text: Font
    public var mono: Font
    public var monoSmall: Font
    /// Small print on a card, like "Published" or "Waiting for you".
    public var caption: Font
    /// How much bigger than usual to draw the steps' icons, so they keep up
    /// with text that's been made bigger.
    public var scale: CGFloat

    public init(text: Font, mono: Font, monoSmall: Font, caption: Font = .caption, scale: CGFloat = 1) {
        self.text = text
        self.mono = mono
        self.monoSmall = monoSmall
        self.caption = caption
        self.scale = scale
    }

    public static let phone = StepFonts(text: .footnote, mono: .system(.footnote, design: .monospaced),
                                        monoSmall: .system(.caption, design: .monospaced))
}

/// The type for Markdown's blocks. Paragraphs take the font around them;
/// the rest comes from here.
public struct MarkdownFonts: Sendable {
    public var heading1: Font
    public var heading2: Font
    public var heading3: Font
    public var code: Font
    public var tableHeader: Font
    public var table: Font
    /// For `code` within a line. Nil leaves it to SwiftUI, which uses the
    /// monospaced version of the font around it.
    public var inlineCode: Font?
    #if os(macOS)
    /// Set to draw runs of prose as one selectable Mac text view.
    public var prose: ProseFonts?
    #endif

    public init(heading1: Font, heading2: Font, heading3: Font, code: Font, tableHeader: Font, table: Font, inlineCode: Font? = nil) {
        self.heading1 = heading1
        self.heading2 = heading2
        self.heading3 = heading3
        self.code = code
        self.tableHeader = tableHeader
        self.table = table
        self.inlineCode = inlineCode
    }

    public func heading(level: Int) -> Font {
        switch level {
        case 1: heading1
        case 2: heading2
        default: heading3
        }
    }

    public static let standard = MarkdownFonts(
        heading1: .system(.title3, design: .rounded, weight: .bold),
        heading2: .system(.body, design: .rounded, weight: .bold),
        heading3: .system(.body, design: .rounded, weight: .semibold),
        code: .system(.footnote, design: .monospaced),
        tableHeader: .footnote.weight(.semibold),
        table: .footnote)
}

/// Link and diff colors for steps. `added` and `removed` are also the one
/// green and the one red for how a step went: "Done" and "Failed".
public enum StepColors {
    public static let link = Color(light: Color(red: 0.11, green: 0.36, blue: 0.85), dark: Color(red: 0.49, green: 0.71, blue: 1.0))
    public static let added = Color(light: Color(red: 0.08, green: 0.45, blue: 0.22), dark: Color(red: 0.56, green: 0.88, blue: 0.71))
    public static let removed = Color(light: Color(red: 0.70, green: 0.13, blue: 0.13), dark: Color(red: 0.97, green: 0.64, blue: 0.62))
    public static let addedFill = Color(red: 0.30, green: 0.76, blue: 0.54).opacity(0.13)
    public static let removedFill = Color(red: 0.96, green: 0.44, blue: 0.40).opacity(0.13)
}

/// A run of tool calls, as a thread: one line a step, hanging from a thin
/// rule, so Claude's words stay the heaviest thing in the conversation.
/// Reading and searching are quiet lines. An edit or a command is a line
/// too, and opens to show what it did. Only things that stand on their own
/// (a plan, a published page, agents at work) are cards.
public struct StepRunView: View {
    let steps: [TranscriptMessage]
    let results: [String: TranscriptMessage]
    let isLive: Bool

    /// `isLive` is true while Claude is still on this run, so its last
    /// step reads as under way.
    public init(steps: [TranscriptMessage], results: [String: TranscriptMessage], isLive: Bool = false) {
        self.steps = steps
        self.results = results
        self.isLive = isLive
    }

    public var body: some View {
        let pieces = StepRunLayout.pieces(for: steps)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(pieces) { piece in
                // A card that joins a run under way fades in. (A thread's
                // lines fade in one by one instead.)
                let isNew = isLive && piece.id == pieces.last?.id
                switch piece {
                case .thread(let items):
                    StepThread(items: items, results: results, liveID: isLive ? steps.last?.id : nil,
                               newestID: isNew ? items.last?.id : nil)
                case .agents(let calls):
                    AgentCard(calls: calls, results: results, isLive: isLive)
                        .fadesIn(ifNew: isNew)
                case .artifact(let step):
                    ArtifactCard(step: step, result: step.toolUseID.flatMap { results[$0] })
                        .fadesIn(ifNew: isNew)
                case .plan(let step):
                    PlanCard(step: step, result: step.toolUseID.flatMap { results[$0] })
                        .fadesIn(ifNew: isNew)
                }
            }
        }
    }
}

/// How a run of steps is laid out: which ones share a thread, which ones
/// share a line, and which get a card.
enum StepRunLayout {
    /// One line on a thread.
    enum Item: Identifiable, Equatable {
        /// Reading and searching, back to back. A long stretch folds.
        case quiet([TranscriptMessage])
        /// Edits to one file, back to back: one line with a count.
        case edit([TranscriptMessage])
        case command(TranscriptMessage)

        var id: String {
            switch self {
            case .quiet(let steps): "q-" + (steps.first?.id ?? "")
            case .edit(let steps): "e-" + (steps.first?.id ?? "")
            case .command(let step): step.id
            }
        }
    }

    enum Piece: Identifiable, Equatable {
        case thread([Item])
        case agents([TranscriptMessage])
        case artifact(TranscriptMessage)
        case plan(TranscriptMessage)

        var id: String {
            switch self {
            case .thread(let items): "t-" + (items.first?.id ?? "")
            case .agents(let calls): "a-" + (calls.first?.id ?? "")
            case .artifact(let step), .plan(let step): step.id
            }
        }
    }

    static func pieces(for steps: [TranscriptMessage]) -> [Piece] {
        var pieces: [Piece] = []
        var thread: [Item] = []
        func flush() {
            if !thread.isEmpty { pieces.append(.thread(thread)) }
            thread = []
        }
        for step in steps {
            if step.startsAgent {
                // Agents started back to back share one card.
                flush()
                if case .agents(let calls) = pieces.last {
                    pieces[pieces.count - 1] = .agents(calls + [step])
                } else {
                    pieces.append(.agents([step]))
                }
            } else if step.artifact != nil {
                flush(); pieces.append(.artifact(step))
            } else if step.tool == .planApproval, step.plan != nil {
                flush(); pieces.append(.plan(step))
            } else if step.edit != nil {
                // Another edit to the file just edited joins its line.
                if case .edit(let edits) = thread.last, let path = step.detail, edits.first?.detail == path {
                    thread[thread.count - 1] = .edit(edits + [step])
                } else {
                    thread.append(.edit([step]))
                }
            } else if step.tool == .shell, !step.isShellRead {
                thread.append(.command(step))
            } else if case .quiet(let quiet) = thread.last {
                thread[thread.count - 1] = .quiet(quiet + [step])
            } else {
                thread.append(.quiet([step]))
            }
        }
        flush()
        return pieces
    }
}

/// A step that joins a run already on screen fades in rather than
/// popping. Steps in a run that's merely scrolling into view don't: only
/// the one under way when it first appears counts as new.
private struct FadesInWhenNew: ViewModifier {
    @State private var shown: Bool

    init(isNew: Bool) { _shown = State(initialValue: !isNew) }

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .onAppear {
                if !shown { withAnimation(.easeOut(duration: 0.15)) { shown = true } }
            }
    }
}

private extension View {
    func fadesIn(ifNew isNew: Bool) -> some View { modifier(FadesInWhenNew(isNew: isNew)) }

    /// What a line opens to show (a diff, a command's output): a soft
    /// tinted block with no outline, so it reads as part of its line.
    func stepBlock(_ palette: CompanionPalette) -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.ink.opacity(0.045))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// The lines of a thread along their rule.
private struct StepThread: View {
    @Environment(\.companionPalette) private var palette
    let items: [StepRunLayout.Item]
    let results: [String: TranscriptMessage]
    /// The step under way, if the run is.
    let liveID: String?
    /// The newest line of a run under way. An edit there starts open, and
    /// folds once the next step arrives.
    let newestID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                switch item {
                case .quiet(let steps):
                    QuietRows(steps: steps, results: results, liveID: liveID)
                case .edit(let edits):
                    EditRow(edits: edits, results: results, isNewest: item.id == newestID)
                        .fadesIn(ifNew: item.id == newestID)
                case .command(let step):
                    CommandRow(step: step, result: step.toolUseID.flatMap { results[$0] }, isRunning: step.id == liveID)
                        .fadesIn(ifNew: step.id == liveID)
                }
            }
        }
        .padding(.leading, 14)
        .overlay(alignment: .leading) {
            Rectangle().fill(palette.hairline.opacity(1.6)).frame(width: 1.5).padding(.vertical, 4)
        }
        .padding(.leading, 6)
    }
}

/// Reading, searching and the like, one line each. Long stretches fold
/// after a few.
private struct QuietRows: View {
    @Environment(\.stepFonts) private var fonts
    let steps: [TranscriptMessage]
    let results: [String: TranscriptMessage]
    let liveID: String?
    @State private var showsAll = false

    private static let folded = 4

    var body: some View {
        // Folded, it keeps the newest steps in view, so the one under way
        // is never hidden behind "more".
        let shown = showsAll || steps.count <= Self.folded + 1 ? steps : Array(steps.suffix(Self.folded))
        VStack(alignment: .leading, spacing: 0) {
            if shown.count < steps.count {
                Button("\(steps.count - shown.count) earlier") {
                    withAnimation(.snappy(duration: 0.2)) { showsAll = true }
                }
                .buttonStyle(.pressable)
                .font(fonts.text)
                .foregroundStyle(StepColors.link)
                .padding(.vertical, 3)
            }
            ForEach(shown) { step in
                let result = step.toolUseID.flatMap { results[$0] }
                TimelineRow(step: step, result: result,
                            failed: result.map { $0.isError == true && !$0.wasDeclined } ?? false,
                            isLive: step.id == liveID)
                    .fadesIn(ifNew: step.id == liveID)
            }
        }
    }
}

private struct TimelineRow: View {
    @Environment(\.companionPalette) private var palette
    @Environment(\.stepFonts) private var fonts
    @Environment(\.openStepFile) private var openFile
    let step: TranscriptMessage
    let result: TranscriptMessage?
    let failed: Bool
    let isLive: Bool
    @State private var isOpen = false

    /// A shell read opens to show the command and what it printed.
    private var opens: Bool { step.tool == .shell && step.detail != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            line
            if isOpen, let command = step.detail {
                ShellReadDetail(command: ShellStep.withoutCD(command), output: result?.wasDeclined == false ? result?.text : nil,
                                failed: failed)
                    .padding(.leading, 22)
                    .padding(.bottom, 4)
                    .transition(.opacity)
            }
        }
    }

    private var line: some View {
        let wording = StepWording(step: step, isLive: isLive)
        return HStack(spacing: 8) {
            Image(systemName: wording.symbol)
                .font(.system(size: 11 * fonts.scale))
                .foregroundStyle(failed ? StepColors.removed : palette.inkMuted)
                .frame(width: 14)
            Text(wording.verb)
                .foregroundStyle(palette.inkMuted)
            if let target = wording.target {
                if let path = wording.path, let openFile {
                    Button(target) { openFile(path) }
                        .buttonStyle(.pressable)
                        .font(fonts.monoSmall)
                        .foregroundStyle(StepColors.link)
                        .help("Open \(path)")
                } else {
                    Text(target)
                        .font(fonts.monoSmall)
                        .foregroundStyle(palette.ink.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if let note = wording.note {
                Text(note)
                    .foregroundStyle(palette.inkMuted)
                    .lineLimit(1)
            }
            if failed {
                // No icon of its own: the row's symbol has already turned red.
                Text("Failed").foregroundStyle(StepColors.removed)
            }
            if isLive {
                ProgressView().controlSize(.mini)
            }
            if opens {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8.5 * fonts.scale, weight: .bold))
                    .foregroundStyle(palette.inkMuted.opacity(0.7))
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
            }
        }
        .font(fonts.text)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            if opens { withAnimation(.snappy(duration: 0.2)) { isOpen.toggle() } }
        }
        .help(step.detail.map(ShellStep.withoutCD) ?? step.text)
    }
}

/// What a shell read ran and printed, under its row once opened.
private struct ShellReadDetail: View {
    @Environment(\.companionPalette) private var palette
    @Environment(\.stepFonts) private var fonts
    let command: String
    let output: String?
    let failed: Bool

    private static let shownLines = 30

    var body: some View {
        let lines = (output ?? "").trimmingCharacters(in: .newlines).components(separatedBy: "\n")
        let hasOutput = output.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
        VStack(alignment: .leading, spacing: 0) {
            Text(command)
                .font(fonts.monoSmall)
                .foregroundStyle(palette.ink.opacity(0.85))
                .lineLimit(4)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            if hasOutput {
                VStack(alignment: .leading, spacing: 3) {
                    Text(lines.prefix(Self.shownLines).joined(separator: "\n"))
                        .foregroundStyle(failed ? StepColors.removed : palette.inkMuted)
                    if lines.count > Self.shownLines {
                        Text("\(lines.count - Self.shownLines) more lines")
                            .foregroundStyle(palette.inkMuted.opacity(0.8))
                    }
                }
                .font(fonts.monoSmall)
                .lineSpacing(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .overlay(alignment: .top) { Rectangle().fill(palette.hairline).frame(height: 1) }
            }
        }
        .stepBlock(palette)
        .padding(.top, 2)
    }
}

extension TranscriptMessage {
    /// A shell command that only looked at things, shown with the reading
    /// and searching rather than as a command card.
    var isShellRead: Bool {
        tool == .shell && edit == nil && detail.flatMap(ShellStep.read) != nil
    }
}

/// A step in a few words for the timeline: past tense once it's done.
struct StepWording {
    var symbol: String
    var verb: String
    var target: String?
    /// The file to open, for steps about one.
    var path: String?
    /// After the target, quieter: "lines 195–205".
    var note: String?

    init(step: TranscriptMessage, isLive: Bool) {
        let detail = step.detail
        let fileName = detail.map { ($0 as NSString).lastPathComponent }
        if step.tool == .shell, let read = detail.flatMap(ShellStep.read) {
            self.init(symbol: read.symbol, verb: isLive ? read.verbNow : read.verbThen, target: read.target, path: read.path)
            note = read.note
            return
        }
        switch step.tool {
        case .read:
            self.init(symbol: "doc.text", verb: isLive ? "Reading" : "Read", target: fileName, path: detail)
        case .search:
            let pattern = detail?.components(separatedBy: " in ").first
            self.init(symbol: "magnifyingglass", verb: isLive ? "Searching for" : "Searched for", target: pattern)
        case .find:
            self.init(symbol: "magnifyingglass", verb: isLive ? "Finding" : "Found", target: detail)
        case .webFetch:
            self.init(symbol: "globe", verb: isLive ? "Reading" : "Read", target: detail.flatMap { URL(string: $0)?.host() })
        case .webSearch:
            self.init(symbol: "globe", verb: isLive ? "Searching the web for" : "Searched the web for", target: detail)
        case .agent:
            self.init(symbol: "person.2", verb: isLive ? "Running a subagent" : "Ran a subagent")
        case .checklist:
            self.init(symbol: "checklist", verb: "Updated its to-do list")
        case .question:
            self.init(symbol: "questionmark.bubble", verb: "Asked you a question")
        case .planApproval:
            self.init(symbol: "list.bullet.clipboard", verb: "Asked you to approve a plan")
        default:
            self.init(symbol: "wrench.adjustable", verb: step.text)
        }
    }

    init(symbol: String, verb: String, target: String? = nil, path: String? = nil) {
        self.symbol = symbol
        self.verb = verb
        self.target = target
        self.path = path
    }
}

/// Edits to a file, or a new one: a line with the file and its line
/// counts, which opens to show the lines that changed. Edits made back to
/// back to one file share the line.
private struct EditRow: View {
    @Environment(\.companionPalette) private var palette
    @Environment(\.stepFonts) private var fonts
    @Environment(\.openStepFile) private var openFile
    @Environment(\.collapsesDiffs) private var collapses
    @Environment(\.stepFileProject) private var fileProject
    let edits: [TranscriptMessage]
    let results: [String: TranscriptMessage]
    /// The newest line of a run under way: its lines show until the next
    /// step arrives, so you can watch the edit Claude just made.
    let isNewest: Bool
    /// Open or shut by your own click, which then outranks `isNewest`.
    @State private var chosen: Bool?
    @State private var isHovering = false

    /// On a phone the lines stay folded until asked for.
    private var isOpen: Bool { chosen ?? (isNewest && !collapses) }

    private var hasLines: Bool {
        edits.contains { step in step.edit.map { !$0.removed.isEmpty || !$0.added.isEmpty } ?? false }
    }

    /// The first edit that failed, if any did.
    private var failure: TranscriptMessage? {
        edits.lazy.compactMap { $0.toolUseID.flatMap { results[$0] } }.first { $0.isError == true && !$0.wasDeclined }
    }

    var body: some View {
        let path = edits.first?.detail
        let name = path.map { ($0 as NSString).lastPathComponent } ?? "a file"
        let isNewFile = edits.first?.edit?.isNewFile == true
        let added = edits.reduce(0) { $0 + ($1.edit?.addedCount ?? 0) }
        let removed = edits.reduce(0) { $0 + ($1.edit?.removedCount ?? 0) }
        let failure = failure
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: isNewFile ? "doc.badge.plus" : "pencil")
                    .font(.system(size: 11 * fonts.scale, weight: .medium))
                    .foregroundStyle(failure == nil ? palette.ink.opacity(0.75) : StepColors.removed)
                    .frame(width: 14)
                Text(isNewFile ? "Wrote" : "Edited")
                    .foregroundStyle(palette.ink.opacity(0.85))
                if let path, let openFile {
                    Button(name) { openFile(path) }
                        .buttonStyle(.pressable)
                        .font(fonts.mono)
                        .foregroundStyle(StepColors.link)
                        .help("Open \(path)")
                } else {
                    Text(name).font(fonts.mono).foregroundStyle(palette.ink)
                }
                HStack(spacing: 5) {
                    if added > 0 { Text("+\(added)").foregroundStyle(StepColors.added) }
                    if removed > 0 { Text("−\(removed)").foregroundStyle(StepColors.removed) }
                }
                .font(fonts.monoSmall)
                if edits.count > 1 {
                    Text("· \(edits.count) edits")
                        .foregroundStyle(palette.inkMuted)
                        .lineLimit(1)
                }
                if let path, let project = fileProject?(path) {
                    StepProjectChip(project: project)
                        .layoutPriority(-1)
                }
                if let failure {
                    // No icon of its own: the line's symbol has already turned red.
                    Text("Failed")
                        .foregroundStyle(StepColors.removed)
                        .help(failure.text)
                }
                if hasLines {
                    StepChevron(isOpen: isOpen)
                }
                Spacer(minLength: 0)
            }
            .font(fonts.text)
            .lineLimit(1)
            .stepLine(opens: hasLines, isHovering: $isHovering) {
                withAnimation(.snappy(duration: 0.2)) { chosen = !isOpen }
            }
            .accessibilityLabel("\(isNewFile ? "Wrote" : "Edited") \(name), \(added) added, \(removed) removed")
            .accessibilityValue(hasLines ? (isOpen ? "Showing its lines" : "Lines hidden") : "")
            if isOpen, hasLines {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(edits) { EditLines(step: $0) }
                }
                .padding(.leading, 22)
                .padding(.top, 2)
                .padding(.bottom, 5)
                .transition(.opacity)
            }
        }
        // Folding as the next step arrives is a change of its own.
        .animation(.snappy(duration: 0.2), value: isNewest)
    }
}

/// The lines one edit took out and put in, as a small diff.
private struct EditLines: View {
    @Environment(\.companionPalette) private var palette
    @Environment(\.stepFonts) private var fonts
    let step: TranscriptMessage
    @State private var showsAll = false

    var body: some View {
        if let edit = step.edit, !edit.removed.isEmpty || !edit.added.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(edit.removed.enumerated()), id: \.offset) { _, line in
                    DiffLineText(sign: "−", line: line, ink: StepColors.removed, fill: StepColors.removedFill)
                }
                ForEach(Array(edit.added.enumerated()), id: \.offset) { _, line in
                    DiffLineText(sign: "+", line: line, ink: StepColors.added, fill: StepColors.addedFill)
                }
                // A plan file keeps all its lines, so they can be shown.
                if showsAll, let all = step.plan?.components(separatedBy: "\n") {
                    ForEach(Array(all.dropFirst(edit.added.count).enumerated()), id: \.offset) { _, line in
                        DiffLineText(sign: "+", line: line, ink: StepColors.added, fill: StepColors.addedFill)
                    }
                }
                let hidden = (edit.removedCount - edit.removed.count) + (edit.addedCount - edit.added.count)
                if hidden > 0 {
                    let label = "\(hidden) more \(hidden == 1 ? "line" : "lines")"
                    if step.plan != nil {
                        Button(showsAll ? "Show fewer lines" : "Show \(label)") {
                            withAnimation(.snappy(duration: 0.2)) { showsAll.toggle() }
                        }
                        .buttonStyle(.pressable)
                        .font(fonts.monoSmall)
                        .foregroundStyle(StepColors.link)
                        .padding(.horizontal, 10)
                        .padding(.top, 3)
                    } else {
                        Text(label)
                            .font(fonts.monoSmall)
                            .foregroundStyle(palette.inkMuted)
                            .padding(.horizontal, 10)
                            .padding(.top, 3)
                    }
                }
            }
            .padding(.vertical, 5)
            .stepBlock(palette)
        }
    }
}

private struct DiffLineText: View {
    @Environment(\.stepFonts) private var fonts
    let sign: String
    let line: String
    let ink: Color
    let fill: Color

    var body: some View {
        Text("\(sign) \(line)")
            .font(fonts.monoSmall)
            .foregroundStyle(ink)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 10)
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Square, so lines run together like a diff instead of pills.
            .background(Rectangle().fill(fill))
    }
}

/// The small arrow on a line that opens.
private struct StepChevron: View {
    @Environment(\.companionPalette) private var palette
    @Environment(\.stepFonts) private var fonts
    let isOpen: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 8.5 * fonts.scale, weight: .bold))
            .foregroundStyle(palette.inkMuted.opacity(0.7))
            .rotationEffect(.degrees(isOpen ? 90 : 0))
            .accessibilityHidden(true)
    }
}

/// A thread line that opens on a click: its spacing, a faint fill under
/// the pointer, and the click itself. A tap, not a button, so a link
/// inside the line (the file's name) still takes its own clicks.
private struct StepLine: ViewModifier {
    @Environment(\.companionPalette) private var palette
    let opens: Bool
    @Binding var isHovering: Bool
    let toggle: () -> Void

    func body(content: Content) -> some View {
        content
            .padding(.vertical, 3)
            .background {
                if opens, isHovering {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(palette.ink.opacity(0.05))
                        .padding(.horizontal, -6)
                }
            }
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .onTapGesture { if opens { toggle() } }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(opens ? .isButton : [])
            .accessibilityAction { if opens { toggle() } }
    }
}

private extension View {
    func stepLine(opens: Bool, isHovering: Binding<Bool>, toggle: @escaping () -> Void) -> some View {
        modifier(StepLine(opens: opens, isHovering: isHovering, toggle: toggle))
    }
}

/// A shell command: a line with the command and how it went, which opens
/// to show the whole command and the end of what it printed. One that
/// failed starts open, since that's when the output matters.
private struct CommandRow: View {
    @Environment(\.companionPalette) private var palette
    @Environment(\.stepFonts) private var fonts
    let step: TranscriptMessage
    let result: TranscriptMessage?
    let isRunning: Bool
    @State private var chosen: Bool?
    @State private var showsAll = false
    @State private var isHovering = false

    /// The command's first line, without the `cd project &&` Claude puts
    /// in front of most of them.
    private var command: String {
        let line = (step.detail ?? step.text).split(whereSeparator: \.isNewline).first.map(String.init) ?? step.text
        return ShellStep.withoutCD(line)
    }

    /// Claude's words for the command ("Ran the tests"), or nil when it
    /// gave none and the command is all there is to show.
    private var title: String? {
        guard let detail = step.detail,
              step.text != ToolWording.literal(tool: ToolKind.shell.name, input: ["command": detail]) else { return nil }
        return result == nil ? step.text : ToolWording.pastClauses(step.text)
    }

    private var output: [String] {
        guard let result, !result.wasDeclined else { return [] }
        let text = result.text.trimmingCharacters(in: .newlines)
        return text.trimmingCharacters(in: .whitespaces).isEmpty ? [] : text.components(separatedBy: "\n")
    }

    private var failed: Bool { result?.isError == true && result?.wasDeclined != true }

    /// There's more to see than the line shows: output, or a command the
    /// line only names.
    private var opens: Bool { !output.isEmpty || title != nil || (step.detail ?? "").contains("\n") }
    private var isOpen: Bool { chosen ?? failed }

    /// Lines shown once open: all of short output, else the end, where
    /// builds and tests say how they went.
    private var tailLength: Int { failed ? 12 : 8 }
    private var folds: Bool { output.count > tailLength + 1 }
    private static let openLimit = 400

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.system(size: 11 * fonts.scale))
                    .foregroundStyle(failed ? StepColors.removed : palette.ink.opacity(0.75))
                    .frame(width: 14)
                if let title {
                    Text(title)
                        .foregroundStyle(palette.ink.opacity(0.85))
                        .layoutPriority(1)
                    Text(command)
                        .font(fonts.monoSmall)
                        .foregroundStyle(palette.inkMuted)
                        .truncationMode(.tail)
                } else {
                    Text(command)
                        .font(fonts.mono)
                        .foregroundStyle(palette.ink.opacity(0.9))
                        .truncationMode(.tail)
                }
                status
                    .layoutPriority(2)
                if opens {
                    StepChevron(isOpen: isOpen)
                }
                Spacer(minLength: 0)
            }
            .font(fonts.text)
            .lineLimit(1)
            .stepLine(opens: opens, isHovering: $isHovering) {
                withAnimation(.snappy(duration: 0.2)) { chosen = !isOpen }
            }
            .help(step.detail ?? command)
            if isOpen, opens {
                detail
                    .padding(.leading, 22)
                    .padding(.top, 2)
                    .padding(.bottom, 5)
                    .transition(.opacity)
            }
        }
    }

    /// The whole command, then the end of its output.
    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(ShellStep.withoutCD(step.detail ?? command))
                .font(fonts.monoSmall)
                .foregroundStyle(palette.ink.opacity(0.85))
                .lineLimit(6)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            if !output.isEmpty {
                let lines = showsAll ? Array(output.suffix(Self.openLimit)) : Array(output.suffix(tailLength))
                VStack(alignment: .leading, spacing: 4) {
                    if folds {
                        Button {
                            withAnimation(.snappy(duration: 0.2)) { showsAll.toggle() }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 8.5 * fonts.scale, weight: .bold))
                                    .rotationEffect(.degrees(showsAll ? 90 : 0))
                                Text(showsAll ? "Show less" : "Show all \(output.count) lines")
                            }
                            .foregroundStyle(StepColors.link)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.pressable)
                        if showsAll, output.count > Self.openLimit {
                            Text("\(output.count - Self.openLimit) earlier lines not shown")
                                .foregroundStyle(palette.inkMuted.opacity(0.8))
                        } else if !showsAll {
                            Text("…").foregroundStyle(palette.inkMuted.opacity(0.7))
                        }
                    }
                    Text(lines.joined(separator: "\n"))
                        .foregroundStyle(failed ? StepColors.removed : palette.inkMuted)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                }
                .font(fonts.monoSmall)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .overlay(alignment: .top) { Rectangle().fill(palette.hairline).frame(height: 1) }
            }
        }
        .stepBlock(palette)
    }

    @ViewBuilder private var status: some View {
        if let result {
            let seconds = bothDates(step.at, result.at).map { $0.1.timeIntervalSince($0.0) }
            // The time includes any wait for your permission, so it's a
            // tooltip rather than a claim about how long the command ran.
            let time = seconds.map { "Finished \(Self.duration($0)) after the agent asked to run it" } ?? ""
            Group {
                if result.wasDeclined {
                    Text("Stopped").foregroundStyle(palette.inkMuted)
                } else if result.isError == true {
                    // No icon of its own: the line's symbol has already turned red.
                    Text("Failed").foregroundStyle(StepColors.removed)
                } else {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9 * fonts.scale, weight: .bold))
                        .foregroundStyle(StepColors.added)
                        .accessibilityLabel("Done")
                }
            }
            .help(time)
        } else if isRunning {
            // A ticking clock, so a long build reads as busy, not stuck.
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                if let started = step.at {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(ActiveTimer.elapsed(context.date.timeIntervalSince(started)))
                            .monospacedDigit()
                    }
                    .foregroundStyle(palette.inkMuted)
                }
            }
        }
    }

    /// "0.4s", "12s", "3m 05s".
    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 10 { return String(format: "%.1fs", max(0.1, seconds)) }
        if seconds < 60 { return "\(Int(seconds))s" }
        return ActiveTimer.elapsed(seconds)
    }
}

private func bothDates(_ a: Date?, _ b: Date?) -> (Date, Date)? {
    guard let a, let b else { return nil }
    return (a, b)
}

extension TranscriptMessage {
    /// True for a result that only says you said no or stopped Claude:
    /// Claude Code's wording for it is meant for Claude, not for you.
    var wasDeclined: Bool {
        guard resultOf != nil, isError == true else { return false }
        return text.hasPrefix("The user doesn't want to proceed") || text.hasPrefix("[Request interrupted")
            || text.hasPrefix("The user doesn't want to take this action")
    }
}

/// A page Claude published, with a button to open it.
private struct ArtifactCard: View {
    @Environment(\.companionPalette) private var palette
    @Environment(\.stepFonts) private var fonts
    @Environment(\.openURL) private var openURL
    let step: TranscriptMessage
    let result: TranscriptMessage?

    private var link: ArtifactLink? {
        guard let found = result?.artifact, !found.url.isEmpty else { return nil }
        return found
    }

    private var title: String {
        if let title = link?.title, !title.isEmpty { return title }
        if let title = step.artifact?.title, !title.isEmpty { return title }
        return "A page"
    }

    private var status: String {
        guard let result else { return "Publishing…" }
        guard let link else { return result.wasDeclined ? "Not published" : result.isError == true ? "Couldn't publish" : "Published" }
        if let version = link.version, version > 1 { return "Updated · version \(version)" }
        return "Published"
    }

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: ArtifactPublish.symbol(for: link?.icon))
                .font(.system(size: 14 * fonts.scale, weight: .semibold))
                .foregroundStyle(palette.accent)
                .frame(width: 32, height: 32)
                .background(palette.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(fonts.text.weight(.semibold))
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                Text(status)
                    .font(fonts.caption)
                    .foregroundStyle(palette.inkMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let link, let url = URL(string: link.url) {
                Button("Open") { openURL(url) }
                    .font(fonts.caption.weight(.semibold))
                    .buttonStyle(.pressable)
                    .foregroundStyle(palette.ink)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(palette.raised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contextMenu {
                        Button("Copy Link") { copy(link.url) }
                    }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(palette.hairline))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(status)")
    }

    private func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}


/// Claude's plan, when it asks you to approve one: the plan itself, so it
/// can be read here instead of in the terminal. Long plans fold after a
/// screenful, with a button to read the rest.
private struct PlanCard: View {
    @Environment(\.companionPalette) private var palette
    @Environment(\.stepFonts) private var fonts
    let step: TranscriptMessage
    let result: TranscriptMessage?
    @State private var isOpen = false
    @State private var height: CGFloat = 0

    /// Plans taller than this fold.
    private let folded: CGFloat = 260

    /// In the colors meant for small text: the palette's amber and green
    /// are for fills, and too light to read at this size.
    private var status: (text: String, color: Color) {
        guard let result else { return ("Waiting for you", palette.waitingInk) }
        if result.isError == true || result.wasDeclined { return ("Not approved", palette.inkMuted) }
        return ("Approved", StepColors.added)
    }

    var body: some View {
        let plan = step.plan ?? ""
        let folds = height > folded + 40
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.clipboard")
                    .font(.system(size: 12 * fonts.scale, weight: .medium))
                    .foregroundStyle(palette.accent)
                Text("Plan")
                    .font(fonts.text.weight(.semibold))
                    .foregroundStyle(palette.ink)
                Spacer(minLength: 8)
                Text(status.text)
                    .font(fonts.caption.weight(.medium))
                    .foregroundStyle(status.color)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .overlay(alignment: .bottom) { Rectangle().fill(palette.hairline).frame(height: 1) }
            MarkdownText(text: plan)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                // Capped even before the plan has been measured. Uncapped, a
                // long plan first lays out at full height and then snaps
                // shut, which jolts the list each time the card scrolls in.
                .frame(maxWidth: .infinity, maxHeight: isOpen ? nil : (folds ? folded : folded + 40), alignment: .topLeading)
                .clipped()
                .overlay(alignment: .bottom) {
                    if folds && !isOpen {
                        LinearGradient(colors: [palette.surface.opacity(0), palette.surface], startPoint: .top, endPoint: .bottom)
                            .frame(height: 56)
                            .allowsHitTesting(false)
                    }
                }
            if folds {
                Button(isOpen ? "Show Less" : "Show Full Plan") {
                    withAnimation(.snappy(duration: 0.25)) { isOpen.toggle() }
                }
                .buttonStyle(.pressable)
                .font(fonts.text.weight(.medium))
                .foregroundStyle(StepColors.link)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
                .padding(.top, 2)
            }
        }
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(palette.hairline))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Plan, \(status.text)")
    }
}
