import AppKit
import BenchKit
import SwiftUI

/// What a sidebar row says about a project, on this Mac or another, as
/// plain data. `ProjectRow` and `RemoteProjectRow` each build one from
/// their own sources, and `SidebarRowBody` draws it the same way for both.
struct SidebarRowModel {
    var name: String
    /// A worktree is marked by a branch glyph in place of its icon.
    var isWorktree: Bool
    var icon: ProjectIconSource
    var activity: TabActivity
    /// While Claude works or waits: when that began, and what it's doing.
    var timer: ActiveTimerModel?
    /// What the tab behind the timer is working on: its name, Claude's
    /// title for the task, or your prompt. With several agents going, the
    /// current step alone doesn't say which job is which.
    var task: String?
    /// Claude's steps for the work under way, when it keeps a list.
    var checklist: [ChecklistItem]?
    /// A quiet row's second line.
    var status: RowStatus?
    /// What Claude is asking, while the row waits on you.
    var waiting: WaitingPrompt?
    /// A turn that finished while you weren't looking, for a row that's done.
    var finished: FinishedSummary?
    /// The latest finished turn, seen or not, for a quiet Standard row.
    var lastFinish: FinishedSummary?
    /// A note in place of the status line.
    var notice: Notice?
    /// Every Claude tab, for a project with several: the card describes
    /// one tab in full and gives each of the others a line.
    var tabs: [TabLine] = []
    /// Claude in another project edited this one.
    var editedFrom: EditedFrom?
    /// For a project on another Mac: that Mac's name, in a pill after the project's.
    var macName: String?
    var notifiesPhone = false
    /// The number shown while Command is held, in place of the activity mark.
    var shortcut: Int?
    /// Set while the name is being edited in place.
    var rename: Rename?

    enum Notice {
        /// Claude was stopped by the app restarting.
        case stoppedByRestart
        /// A merged agent's worktree is waiting to be cleaned up: what would be lost.
        case leftovers(String)
    }

    struct EditedFrom {
        /// The project whose Claude made the edits.
        var name: String
        /// True while that Claude is still at it.
        var isLive: Bool
    }

    struct Rename {
        /// Shown while the field is empty: the folder's name.
        var placeholder: String
        /// The name as it is now.
        var name: String
    }
}

/// Where a row's icon comes from: a project on this Mac and its image, or
/// one on another Mac and the PNG that Mac sent.
enum ProjectIconSource {
    case local(Project, NSImage?)
    case remote(CompanionProject, Data?)
}

struct ActiveTimerModel {
    var since: Date
    /// What Claude is doing, in words.
    var action: String?
    /// The tab it's about, when the project has several.
    var tabID: UUID?
}

struct WaitingPrompt {
    var question: String?
    /// The tool it wants to run, for a plain allow-or-deny question.
    var action: String?
    /// True when Allow and Deny buttons can answer it from here.
    var canAnswer: Bool
}

struct FinishedSummary {
    var recap: String
    var at: Date?
    /// What's left uncommitted.
    var changes: [FileChange] = []
    /// The tab that finished, when the project has several.
    var tabID: UUID?
}

/// What a row's buttons and field do; the row that owns the project fills these in.
struct SidebarRowActions {
    var allow: () -> Void = {}
    var deny: () -> Void = {}
    var cleanUp: () -> Void = {}
    /// Finishes renaming: the new name to save, or nil to keep the old one.
    var rename: (String?) -> Void = { _ in }
    /// Starts an agent on its own branch. Set on the row of the project
    /// you're in, which shows a button for it.
    var newAgent: (() -> Void)?
}

/// A round chip with a plus at the trailing edge of the row of the
/// project you're in: starts Claude on its own branch and worktree. While
/// the pointer is over the row it grows the word "Agent", so it says what
/// it does without taking room from the project's name the rest of the time.
struct NewAgentButton: View {
    static let collapsedWidth: CGFloat = 22
    static let height: CGFloat = 20
    /// True while the pointer is anywhere over the row.
    let isRowHovering: Bool
    let action: () -> Void
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "plus")
                    .font(.ui(size: 9.5, weight: .bold))
                if isRowHovering {
                    Text("Agent")
                        .font(.ui(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
            .foregroundStyle(isHovering ? Theme.onAccent : Color.primary)
            .padding(.horizontal, 6)
            .frame(minWidth: Self.collapsedWidth, minHeight: Self.height)
            .background {
                Capsule(style: .continuous)
                    .fill(isHovering ? Theme.accent : Color.primary.opacity(0.07))
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.primary.opacity(isHovering ? 0 : 0.12), lineWidth: 1)
            }
            .clipShape(Capsule(style: .continuous))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.pressableChip)
        .fixedSize()
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isRowHovering)
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help("New Agent on a Branch: start an agent on its own branch and worktree (⇧⌘N)")
        .accessibilityLabel("New Agent on a Branch")
    }
}

/// Everything inside a project row: its icon, name, what Claude is doing
/// or did, and the activity mark or shortcut at the trailing edge.
struct SidebarRowBody: View {
    let model: SidebarRowModel
    let isSelected: Bool
    /// Recent and Inactive: a smaller icon, a lighter name, no status line.
    let compact: Bool
    let actions: SidebarRowActions
    /// True while the pointer is over the row, which lets the new agent
    /// button show its label.
    var isHovering = false
    @AppStorage(SidebarLayout.key) private var layout = SidebarLayout.standard
    /// Where the new agent button's collapsed chip sits in the row, and
    /// how wide the chip is right now. It grows over the row's text, so
    /// the row's layout never changes when it says "Agent".
    @State private var agentSlot = CGRect.zero
    @State private var agentWidth: CGFloat = NewAgentButton.collapsedWidth
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let space = "SidebarRowBody"
    private static let maskOutset: CGFloat = 2

    var body: some View {
        // Standard rows in the tray have room for what the agent is doing and did.
        let standard = !compact && layout == .standard
        HStack(alignment: standard ? .top : .center, spacing: compact ? 8 : 10) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                if standard {
                    // The chip and activity mark share the name's line, so
                    // the lines under it run the full width of the row.
                    HStack(spacing: 10) {
                        title
                        Spacer(minLength: 0)
                        trailingControls(standard: true)
                    }
                } else {
                    title
                }
                detail(standard: standard)
                if standard, model.tabs.count > 1 {
                    OtherTabsList(lines: model.tabs.filter { $0.id != describedTabID(standard: standard) })
                        .padding(.top, 4)
                }
            }
            if !standard {
                Spacer(minLength: 0)
                trailingControls(standard: false)
            }
        }
        .coordinateSpace(.named(Self.space))
        // The hint draws over the trailing edge rather than taking a place
        // in the row, so holding Command doesn't reflow the text. Text
        // that runs that far fades out under it. The same goes for the new
        // agent chip while it's wide.
        .mask { rowMask }
        .overlay(alignment: .topLeading) {
            if showsNewAgent, let newAgent = actions.newAgent, agentSlot != .zero {
                NewAgentButton(isRowHovering: isHovering, action: newAgent)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { agentWidth = width }
                    }
                    // Its trailing edge on the slot's, so it grows leftward.
                    .frame(width: agentSlot.maxX, height: NewAgentButton.height, alignment: .trailing)
                    .offset(y: agentSlot.midY - NewAgentButton.height / 2)
                    .opacity(model.shortcut == nil ? 1 : 0)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: standard ? .topTrailing : .trailing) {
            if let shortcut = model.shortcut {
                Text("⌘\(shortcut)")
                    .font(.ui(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .padding(.top, standard ? 2 : 0)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, compact ? 4 : 6)
    }

    /// What of the row shows: all of it, a little past its edges so a mark
    /// drawn slightly bigger than its box (the green check) isn't cut flat,
    /// less a fade at the trailing edge under the ⌘ hint, or beside the new
    /// agent chip while it's wide. Built only from shapes that show: a cut
    /// out with a blend mode in an offscreen layer sometimes came out empty,
    /// blanking the whole row until the pointer passed over it.
    @ViewBuilder
    private var rowMask: some View {
        let outset = Self.maskOutset
        if model.shortcut != nil {
            HStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 8)
                Color.clear.frame(width: 20 + outset)
            }
            .padding([.leading, .vertical], -outset)
        } else if showsNewAgent, agentWidth > NewAgentButton.collapsedWidth + 0.5 {
            // Only beside the chip, so lines under it keep their full width.
            let start = agentSlot.maxX - agentWidth - 4
            let top = agentSlot.midY - NewAgentButton.height / 2
            VStack(spacing: 0) {
                Color.black.frame(height: max(0, top + outset))
                HStack(spacing: 0) {
                    Color.black.frame(width: max(0, start - 8 + outset))
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 8)
                    Color.clear.frame(width: max(0, agentSlot.minX - start))
                    Color.black
                }
                .frame(height: NewAgentButton.height)
                Color.black
            }
            .padding(-outset)
        } else {
            Color.black.padding(-outset)
        }
    }

    @ViewBuilder
    private var title: some View {
        if let rename = model.rename {
            SidebarRowNameField(rename: rename, finish: actions.rename)
        } else {
            nameLine
        }
    }

    /// The new agent chip's slot and the activity mark, at the trailing edge.
    @ViewBuilder
    private func trailingControls(standard: Bool) -> some View {
        // In the row rather than under it: a row of its own under the
        // selected project made the whole list shift on every switch.
        // Only the collapsed chip's room is kept here. The chip itself
        // draws over the row (below), so growing "Agent" on hover
        // doesn't narrow the text beside it and rewrap the lines. On a
        // Standard row the slot takes no height, so the name's line
        // keeps its own.
        if showsNewAgent {
            Color.clear
                .frame(width: NewAgentButton.collapsedWidth, height: standard ? 0 : NewAgentButton.height)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { agentSlot = $0 }
        }
        ActivityIndicator(activity: model.activity, size: 11)
            .opacity(model.shortcut == nil ? 1 : 0)
    }

    private var showsNewAgent: Bool { actions.newAgent != nil && model.rename == nil }

    @ViewBuilder
    private var icon: some View {
        if model.isWorktree {
            Image(systemName: "arrow.triangle.branch")
                .font(.ui(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
        } else {
            switch model.icon {
            case .local(let project, let image):
                ProjectIcon(project: project, image: image, size: compact ? 18 : 28)
            case .remote(let project, let icon):
                CompanionProjectIcon(project: project, icon: icon, size: compact ? 18 : 28)
            }
        }
    }

    private var nameLine: some View {
        // The Mac pill sits 5pt from the name, the phone bell 4pt.
        HStack(spacing: model.macName == nil ? 4 : 5) {
            Text(model.name)
                .font(.ui(size: compact ? 12 : 13, weight: isSelected ? .semibold : compact ? .regular : .medium))
                .foregroundStyle(Color.primary.opacity(isSelected ? 1 : compact ? 0.78 : 0.85))
                .lineLimit(1)
                .truncationMode(.middle)
                // The name keeps its room next to the pill, which truncates instead.
                .layoutPriority(model.macName == nil ? 0 : 1)
                .help(model.name)
            if model.notifiesPhone {
                Image(systemName: "bell.fill")
                    .font(.ui(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.Status.attention)
                    .help("Sending notifications to your iPhone")
                    .accessibilityLabel("Sending notifications to your iPhone")
            }
            if let macName = model.macName {
                MacNamePill(name: macName)
            }
        }
    }

    /// The tab `detail` describes in full, so it doesn't get a line too.
    /// Follows the same order as `detail`.
    private func describedTabID(standard: Bool) -> UUID? {
        if let timer = model.timer { return timer.tabID }
        if model.activity == .done, let finished = model.finished { return finished.tabID }
        if model.notice != nil || compact || model.editedFrom != nil { return nil }
        return standard ? model.lastFinish?.tabID : nil
    }

    /// The lines under the name, by what matters most: work under way, a
    /// turn that finished unseen, a note, then a quiet row's status.
    @ViewBuilder
    private func detail(standard: Bool) -> some View {
        if let timer = model.timer {
            // Steps done shows on a row that's busy with a checklist.
            let checklist = model.checklist
            if standard, let task = model.task {
                Text(task)
                    .font(.ui(size: 11, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(task)
            }
            ActiveTimerLine(since: timer.since,
                            action: model.activity == .waiting ? nil : (checklist?.current?.label ?? timer.action),
                            activity: CompanionSnapshots.kind(model.activity),
                            lines: standard ? 2 : 1)
            if standard {
                // Only what's under way: past tool calls cut to a few words
                // said little, and moved the row on every call. The chat
                // has every step in full.
                if model.activity == .waiting, let waiting = model.waiting {
                    WaitingDetail(prompt: waiting, allow: actions.allow, deny: actions.deny)
                }
            }
            if let checklist {
                ChecklistStepsBar(items: checklist, activity: CompanionSnapshots.kind(model.activity))
                    .padding(.top, 4)
                    .padding(.bottom, 1)
            }
        } else if model.activity == .done, let finished = model.finished {
            if standard {
                FinishedDetail(recap: finished.recap, at: finished.at, changes: finished.changes, lines: 3)
            } else {
                Text(finished.recap)
                    .font(.ui(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(finished.recap)
            }
        } else if let notice = model.notice {
            switch notice {
            case .stoppedByRestart:
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.ui(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Text("Stopped by the restart")
                        .lineLimit(1)
                }
                .font(.ui(size: 11))
                .foregroundStyle(.secondary)
            case .leftovers(let summary):
                HStack(spacing: 6) {
                    Text(summary)
                        .lineLimit(1)
                        .help(summary)
                    Button("Clean Up", action: actions.cleanUp)
                        .buttonStyle(.link)
                }
                .font(.ui(size: 11))
                .foregroundStyle(.secondary)
            }
        } else if !compact {
            if let from = model.editedFrom {
                EditedFromLine(from: from)
            } else if standard, let finish = model.lastFinish {
                FinishedDetail(recap: finish.recap, at: finish.at, changes: [], lines: 2)
            }
            if let status = model.status {
                RowStatusLine(status: status, lines: standard ? 2 : 1)
                    .padding(.top, standard ? 2 : 0)
            }
        }
    }
}

/// Under a card for a project with several Claude tabs: a line for each
/// tab the card doesn't already describe, with its mark, what it's about,
/// and what it's up to.
struct OtherTabsList: View {
    let lines: [TabLine]
    /// More than this and the rest are counted, not listed.
    static let limit = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(lines.prefix(Self.limit)) { line in
                HStack(spacing: 5) {
                    ZStack {
                        if line.activity == .idle {
                            Circle().strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1)
                                .frame(width: 6, height: 6)
                        } else {
                            ActivityIndicator(activity: line.activity, size: 8)
                        }
                    }
                    .frame(width: 9)
                    Text(line.label)
                        .foregroundStyle(.primary.opacity(0.8))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(line.state)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                .help(line.detail.map { "\(line.label)\n\n\($0)" } ?? line.label)
            }
            if lines.count > Self.limit {
                let more = lines.count - Self.limit
                Text(more == 1 ? "1 more tab" : "\(more) more tabs")
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 14)
            }
        }
        .font(.ui(size: 11))
    }
}

/// "Edited from QuickReads Chrome": Claude in another project changed
/// files here.
private struct EditedFromLine: View {
    let from: SidebarRowModel.EditedFrom

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.turn.down.right")
                .font(.ui(size: 9, weight: .semibold))
                .foregroundStyle(from.isLive ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
            Text(from.isLive ? "Editing from \(from.name)" : "Edited from \(from.name)")
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.ui(size: 11))
        .foregroundStyle(.secondary)
        .help(from.isLive ? "The agent in \(from.name) is changing files here" : "The agent in \(from.name) changed files here since you last looked")
    }
}

/// Edits the name in place, like renaming in Finder. Return or clicking
/// away saves it, Escape keeps the old one, and an empty name goes back
/// to the folder's.
private struct SidebarRowNameField: View {
    let rename: SidebarRowModel.Rename
    let finish: (String?) -> Void
    @State private var draftName = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        TextField(rename.placeholder, text: $draftName)
            .textFieldStyle(.plain)
            .font(.ui(size: 13, weight: .semibold))
            .focused($nameFocused)
            .onAppear {
                draftName = rename.name
                nameFocused = true
            }
            .onSubmit { finish(draftName) }
            .onExitCommand { finish(nil) }
            .onChange(of: nameFocused) { _, focused in
                if !focused { finish(draftName) }
            }
    }
}

/// A row's background and outline: a tint for its activity, a fill while
/// the pointer is over it, and for the selected project a raised card with
/// an accent wash and a thick accent ring. Activity is a tint with no
/// outline here, so the ring is the only line in the sidebar and the
/// project you're in is easy to find with many agents working.
struct SidebarRowChrome: ViewModifier {
    let activity: TabActivity
    let isSelected: Bool
    let isHovering: Bool

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    // The selected project sits on a raised card, so it stands out
                    // even when other rows are tinted by their activity.
                    if isSelected {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .shadow(color: .black.opacity(0.14), radius: 3, y: 1)
                    }
                    ActivityBackground(activity: activity, showsOutline: false)
                    // A wash of the accent on top, so the selected card stays
                    // lighter (or darker) than its neighbors even where the
                    // theme makes the raised card nearly match the sidebar.
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(isSelected ? Theme.accent.opacity(0.14) : Color.primary.opacity(isHovering ? 0.05 : 0))
                }
            }
            .overlay {
                // A solid accent ring marks the selection. No other row has an
                // outline, so nothing competes with it.
                if isSelected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Theme.accent, lineWidth: 3)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: isSelected)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}
