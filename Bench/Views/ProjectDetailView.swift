import BenchKit
import SwiftUI

/// The center pane: a tab bar and the selected tab's terminal.
struct ProjectDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(TerminalManager.self) private var terminals
    @Environment(RepoMonitors.self) private var monitors
    @Environment(PreviewPages.self) private var previews
    @Environment(FileListMonitors.self) private var files
    let project: Project

    var body: some View {
        VStack(spacing: 0) {
            AccountsFoundBanner()
            // The card runs up to the top of the window, its tab row in
            // line with the traffic lights, so there's no band over it.
            VStack(spacing: 0) {
                TabBar(project: project)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .canvasCard()
            .padding([.horizontal, .bottom], TerminalCard.margin)
            .padding(.top, CardBand.topInset)
        }
        .ignoresSafeArea(.container, edges: .top)
        .navigationTitle(project.name)
        #if DEBUG
        // BENCH_FLIP_CHAT=<seconds> switches the current Claude tab between
        // terminal and chat on a timer, for testing without a keyboard.
        .task {
            guard let seconds = ProcessInfo.processInfo.environment["BENCH_FLIP_CHAT"].flatMap(Double.init) else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                if let tab = project.selectedTab, tab.kind == .agent {
                    store.setShowsChat(store.project(project.id)?.selectedTab?.showsChat != true, tab: tab.id, in: project.id)
                }
            }
        }
        #endif
    }

    /// The selected tab's content, set into the window as a rounded card.
    @ViewBuilder private var content: some View {
        Group {
            if let error = terminals.startupError {
                ContentUnavailableView("Terminal Unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if !store.showsStartPage(project), let tab = project.selectedTab {
                if let split = project.split(of: tab.id),
                   let first = project.tabs.first(where: { $0.id == split.first }),
                   let second = project.tabs.first(where: { $0.id == split.second }) {
                    SplitPanes(project: project, split: split, first: first, second: second, focusedID: tab.id)
                } else {
                    TabContent(project: project, tab: tab)
                }
            } else {
                LocalProjectStart(project: project)
                    .id(project.id)
            }
        }
    }
}

/// One tab's content: its terminal (or chat), page, file, or diff. In a
/// split there are two of these, and only the focused one takes the keys.
private struct TabContent: View {
    /// How long the chat takes to fade in over the terminal, or off it.
    private static let chatFade = 0.15
    @Environment(AppStore.self) private var store
    @Environment(TerminalManager.self) private var terminals
    @Environment(RepoMonitors.self) private var monitors
    @Environment(PreviewPages.self) private var previews
    @Environment(FileListMonitors.self) private var files
    let project: Project
    let tab: TabRecord
    var isFocused = true
    var cornerRadius: CGFloat = TerminalCard.radius

    var body: some View {
        if tab.kind == .preview {
            PreviewView(page: previews.page(for: tab.id, url: tab.pageURL ?? tab.previewURL), home: tab.previewURL,
                        tabID: tab.id, projectID: project.id)
                .id(tab.id)
        } else if tab.kind == .file, let path = tab.filePath {
            FileView(project: project, path: path, monitor: files.monitor(for: project), tabID: tab.id, isFocused: isFocused)
                .id("\(tab.id)\(path)")
        } else if tab.kind == .review, let target = tab.review {
            ReviewView(project: project, monitor: monitors.monitor(for: project), target: target, tabID: tab.id)
                .id(tab.id)
        } else if let change = tab.diff {
            DiffView(project: project, monitor: monitors.monitor(for: project), change: change, tabID: tab.id, isFocused: isFocused)
                .id("\(tab.id)\(change.id)")
        } else {
            terminal
        }
    }

    @ViewBuilder private var terminal: some View {
        // Sessions outlive this view, so switching to a diff tab
        // and back doesn't restart the shell.
        let session = terminals.session(for: tab, in: project)
        let chat = tab.kind == .agent && tab.showsChat == true && session.remoteHost == nil
        ZStack {
            // Kept in place and full size under the chat, so
            // Claude's screen keeps its shape and the shell runs on.
            TerminalHost(session: session, background: TerminalTheme.shared.background, cornerRadius: cornerRadius,
                         takesFocus: !chat && isFocused)
                .opacity(chat ? 0 : 1)
                // The terminal never fades. It stays whole under the chat
                // while the chat fades in over it, and is hidden once the
                // chat covers it; going back, it's whole again at once and
                // the chat fades off it. Fading both left each at half
                // strength, the terminal's text showing through the chat.
                .transaction(value: chat) { $0.animation = chat ? .linear(duration: 0.01).delay(Self.chatFade) : nil }
                .allowsHitTesting(!chat)
                .accessibilityHidden(chat)
            if chat {
                LocalChatView(tab: tab, projectID: project.id)
                    .id(tab.id)
                    .environment(\.tabHasKeys, isFocused)
                    .transition(.opacity)
            }
        }
        // The chat fades in over the terminal, quicker than the toggle's
        // pill slides. From the keyboard (⌥⌘T) it's instant.
        .animation(.easeOut(duration: Self.chatFade), value: chat)
        .overlay(alignment: .top) {
            if tab.kind == .agent {
                StoppedByRestartBanner(tabID: tab.id, session: session)
                    .padding(.top, 12)
            }
        }
        .onChange(of: chat) { _, chat in
            guard isFocused else { return }
            DispatchQueue.main.async {
                guard let window = session.view.window else { return }
                if !chat {
                    // Back to the terminal: typing goes there again.
                    window.makeFirstResponder(session.view)
                } else if window.firstResponder === session.view {
                    // The hidden terminal mustn't take keys
                    // meant for the chat, like Return to allow.
                    window.makeFirstResponder(nil)
                }
            }
        }
    }
}

/// Two tabs at once, side by side or stacked, with a divider to drag.
/// The focused side is the project's selected tab; the other is dimmed a
/// little.
private struct SplitPanes: View {
    @Environment(AppStore.self) private var store
    let project: Project
    let split: TabSplit
    let first: TabRecord
    let second: TabRecord
    let focusedID: UUID
    /// The divider's place while it's being dragged, saved when let go.
    @State private var dragFraction: Double?
    @AppStorage(FocusRingColor.key) private var ringColor = FocusRingColor.blue

    static let gap: CGFloat = 6

    private var sideBySide: Bool { split.axis == .sideBySide }

    var body: some View {
        GeometryReader { geometry in
            let total = sideBySide ? geometry.size.width : geometry.size.height
            let usable = max(total - Self.gap, 0)
            let fraction = dragFraction ?? split.fraction
            let firstLength = (usable * fraction).rounded()
            let layout = sideBySide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                pane(first)
                    .frame(width: sideBySide ? firstLength : nil, height: sideBySide ? nil : firstLength)
                SplitDivider(axis: split.axis) { location in
                    let along = sideBySide ? location.x : location.y
                    let raw = Double((along - Self.gap / 2) / max(usable, 1))
                    dragFraction = min(max(raw, TabSplit.fractionRange.lowerBound), TabSplit.fractionRange.upperBound)
                } ended: {
                    if let dragFraction { store.setSplitFraction(dragFraction, of: split.first, in: project.id) }
                    dragFraction = nil
                } reset: {
                    store.setSplitFraction(0.5, of: split.first, in: project.id)
                }
                .frame(width: sideBySide ? Self.gap : nil, height: sideBySide ? nil : Self.gap)
                pane(second)
            }
        }
        .coordinateSpace(.named(SplitDivider.space))
    }

    private func pane(_ tab: TabRecord) -> some View {
        let focused = tab.id == focusedID
        return TabContent(project: project, tab: tab, isFocused: focused)
            .clipShape(TerminalCard.shape)
            .overlay {
                // A ring around the side you're typing in, and the other
                // side dimmed, like Ghostty's splits.
                if focused {
                    TerminalCard.shape
                        .strokeBorder(TerminalTheme.shared.focusRing(ringColor).opacity(0.9), lineWidth: 2)
                        .allowsHitTesting(false)
                } else {
                    TerminalCard.shape
                        .fill(Color(nsColor: TerminalTheme.shared.background ?? .black).opacity(0.3))
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.15), value: focused)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // A click on a chat or page side moves focus there too. A
            // terminal side reports its own clicks as it takes the keys.
            .simultaneousGesture(TapGesture().onEnded {
                if !focused { store.selectTab(tab.id, in: project.id) }
            })
    }
}

/// The handle between two panes: drag to resize, double-click to even out.
private struct SplitDivider: View {
    static let space = "split"
    let axis: TabSplit.Axis
    let changed: (CGPoint) -> Void
    let ended: () -> Void
    let reset: () -> Void
    @State private var isHovering = false
    @State private var isDragging = false

    var body: some View {
        ZStack {
            Color.clear
            // A hairline so the two sides read as separate.
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(width: axis == .sideBySide ? 1 : nil, height: axis == .sideBySide ? nil : 1)
            Capsule()
                .fill(Color.primary.opacity(isHovering || isDragging ? 0.45 : 0))
                .frame(width: axis == .sideBySide ? 3 : 32, height: axis == .sideBySide ? 32 : 3)
        }
        .contentShape(Rectangle())
        .pointerStyle(axis == .sideBySide ? .columnResize : .rowResize)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering || isDragging)
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
                .onChanged { value in
                    isDragging = true
                    changed(value.location)
                }
                .onEnded { _ in
                    isDragging = false
                    ended()
                }
        )
        .onTapGesture(count: 2, perform: reset)
        .help("Drag to resize. Double-click to make both sides the same size.")
        .accessibilityLabel("Split divider")
    }
}

/// A project on this Mac with no tabs open.
private struct LocalProjectStart: View {
    @Environment(AppStore.self) private var store
    @Environment(TerminalManager.self) private var terminals
    @Environment(TabShortcuts.self) private var shortcuts
    @Environment(RepoMonitors.self) private var monitors
    @Environment(ProjectIcons.self) private var icons
    let project: Project
    @State private var recents: [ProjectStartView<ProjectIcon>.Recent]?
    @State private var openTabs: [String: UUID] = [:]

    var body: some View {
        ProjectStartView(
            icon: ProjectIcon(project: project, image: icons.image(for: project), size: 76, outlined: false),
            name: project.isWorktree ? (monitors.monitor(for: project).snapshot?.branch ?? project.name) : project.name,
            branch: project.isWorktree ? nil : monitors.monitor(for: project).snapshot?.branch,
            startShortcut: "⌘T",
            start: { store.addTab(.agent, to: project.id) },
            agentName: Agents.standard.name,
            agentSymbol: Agents.standard.symbol,
            actions: Agents.offered.filter { $0.id != Agents.standard.id }.map { agent in
                .init(title: "New \(agent.name) Tab", symbol: agent.symbol) { store.addTab(.agent, to: project.id, agent: agent.id) }
            } + [
                .init(title: "New Shell Tab", symbol: "terminal", shortcut: "⇧⌘T") { store.addTab(.shell, to: project.id) },
                .init(title: "New Browser Tab", symbol: "globe", shortcut: "⌃⌘T") { store.openBrowserTab(in: project.id) },
                .init(title: "New Agent on a Branch…", symbol: "arrow.triangle.branch", shortcut: "⇧⌘N") {
                    store.startNewAgent(from: project.id)
                },
            ],
            shortcuts: shortcutActions,
            editsShortcuts: true,
            recents: recents,
            resume: resume,
            tint: icons.tint(for: project))
        .task(id: project.id) {
            openTabs = AgentSessions.openSessions()
            let sessions = await SessionHistory.load(projectPath: project.path)
            recents = sessions.prefix(4).map { session in
                .init(id: session.id, title: session.title ?? session.firstPrompt ?? "Untitled",
                      detail: session.title == nil ? nil : (session.lastPrompt ?? session.firstPrompt),
                      modified: session.modified,
                      isOpen: openTabs[session.id].map { tab in project.tabs.contains { $0.id == tab } } ?? false)
            }
        }
    }

    /// The dev server and your own shortcuts, as on the + menu.
    private var shortcutActions: [ProjectStartView<ProjectIcon>.Action] {
        var actions: [ProjectStartView<ProjectIcon>.Action] = []
        if shortcuts.showsDevButton, let dev = PackageManager.devCommand(in: project.url) {
            actions.append(.init(title: dev, symbol: "play.fill", tint: .green, monospaced: true) { run(dev, reuse: true) })
        }
        for shortcut in shortcuts.shortcuts(for: project) {
            actions.append(.init(title: shortcut.name, symbol: shortcut.symbol,
                                 tint: shortcut.command.hasPrefix("ssh ") ? ActivityBackground.remote : nil) {
                run(shortcut.command, reuse: shortcut.reusesRunningTab)
            })
        }
        return actions
    }

    /// Opens a tab running `command`, or switches to one still running it.
    private func run(_ command: String, reuse: Bool) {
        if reuse, let existing = project.tabs.last(where: { $0.command == command }), terminals.isRunning(existing.id) {
            store.selectTab(existing.id, in: project.id)
        } else {
            store.addTab(.shell, to: project.id, command: command)
        }
    }

    private func resume(_ recent: ProjectStartView<ProjectIcon>.Recent) {
        if let tab = openTabs[recent.id], project.tabs.contains(where: { $0.id == tab }) {
            store.selectTab(tab, in: project.id)
        } else {
            let title = recent.title.count > 24 ? String(recent.title.prefix(23)) + "…" : recent.title
            store.addTab(.agent, to: project.id, resuming: recent.id, title: title)
        }
    }
}

/// Shown on a Claude tab that Workbench's last quit stopped partway, with
/// a button to have Claude carry on and send what was queued.
private struct StoppedByRestartBanner: View {
    @Environment(TerminalManager.self) private var terminals
    let tabID: UUID
    let session: TerminalSession
    @State private var problem: String?

    private var agentName: String { (session.agent ?? Agents.standard).name }

    var body: some View {
        if let note = RestartRecovery.shared.stopped(tabID: tabID, lastPrompt: session.details?.promptAt) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.ui(size: 16))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(note.wasWaiting ? "The restart cut off \(agentName)'s question" : "The restart stopped \(agentName) partway")
                        .font(.ui(size: 12, weight: .semibold))
                    Text(problem ?? detail(note))
                        .font(.ui(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Button("Continue") {
                    problem = RestartRecovery.shared.continueTab(tabID, terminals: terminals)
                }
                .buttonStyle(.prominent)
                Button {
                    RestartRecovery.shared.dismiss(tabID)
                } label: {
                    Image(systemName: "xmark")
                        .font(.ui(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                // A 20pt target that takes the mark's own room in the row.
                .padding(-5)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            }
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.accent.opacity(0.35)))
            .frame(maxWidth: 520)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func detail(_ note: RestartRecovery.Stopped) -> String {
        let queued = note.queued.count
        let base = "Continue asks it to pick up where it left off"
        switch queued {
        case 0: return base + "."
        case 1: return base + ", then sends the message you'd queued."
        default: return base + ", then sends the \(queued) messages you'd queued."
        }
    }
}

/// A Claude tab on this Mac as a conversation.
private struct LocalChatView: View {
    @Environment(AppStore.self) private var store
    @Environment(TerminalManager.self) private var terminals
    @Environment(ProjectIcons.self) private var icons
    @Environment(FileListMonitors.self) private var files
    let tab: TabRecord
    let projectID: UUID
    @State private var source: LocalChatSource?

    var body: some View {
        // Something always on screen, or onAppear never fires to make the source.
        ZStack {
            TerminalTheme.shared.chatPalette.canvas
            if let source {
                ChatSessionView(source: source)
                    .environment(\.stepFileProject, otherProject)
                    .environment(\.turnReview, turnReview)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            guard source == nil else { return }
            ChatTiming.note("chat view appeared", tab: tab.id)
            let store = store, tabID = tab.id, projectID = projectID
            let monitor = store.project(projectID).map { files.monitor(for: $0) }
            source = LocalChatSource(tab: tab, terminals: terminals, files: monitor) {
                store.setShowsChat(false, tab: tabID, in: projectID, byUser: false)
            } openFile: { path in
                // Files in the project open by their place in it. Others,
                // like Claude's plans, open by their full path.
                guard let root = store.project(projectID)?.path else { return }
                let prefix = root.hasSuffix("/") ? root : root + "/"
                if path.hasPrefix(prefix) {
                    store.openFile(String(path.dropFirst(prefix.count)), in: projectID)
                } else if FileManager.default.fileExists(atPath: path) {
                    store.openFile(path, in: projectID)
                } else {
                    NSSound.beep()
                }
            } revealFile: { text in
                // A path in a reply, clicked: show the file in the Finder.
                // Anything that isn't one copies, as code always has.
                guard let path = LocalFilePath.resolve(text, root: store.project(projectID)?.path) else { return false }
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                return true
            }
        }
    }

    /// What a click on a turn's changed files does: opens that turn in a
    /// review tab, at the file clicked.
    private var turnReview: TurnReviewActions {
        let store = store, projectID = projectID, tabID = tab.id
        return TurnReviewActions(root: store.project(projectID)?.path) { turn, file in
            store.openTurnReview(.turn(turn.id, inTab: tabID), file: file.path, in: projectID)
        } reviewAll: { turn in
            store.openTurnReview(.turn(turn.id, inTab: tabID), in: projectID)
        }
    }

    /// The other Workbench project a file is in, for the chip on Claude's
    /// edits there. Clicking the chip opens that project.
    private func otherProject(_ path: String) -> StepFileProject? {
        guard let id = terminals.project(holding: path), id != projectID,
              let project = store.project(id) else { return nil }
        let store = store
        return StepFileProject(name: project.name,
                               icon: AnyView(ProjectIcon(project: project, image: icons.image(for: project), size: 13)),
                               open: { store.selectedProjectID = id })
    }
}

/// The terminal sits in the window like a card, inset from the edges with
/// rounded corners, rather than running into them.
enum TerminalCard {
    static let radius: CGFloat = 10
    static let margin: CGFloat = 6
    static var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }
    /// The light catching the card's top edge in a dark window, strongest
    /// along the top and gone a little way down the sides. The open tab
    /// wears the same, so the two still read as one sheet.
    static let topLight = LinearGradient(colors: [.white.opacity(0.11), .white.opacity(0)],
                                         startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.5))
}

/// Sets content into the window as the canvas card: a sheet resting on the
/// window, not a panel level with it. A dark window shows that with light
/// along the card's top edge, where a shadow would be lost; a light one
/// with a soft shadow under it.
private struct CanvasCard: ViewModifier {
    var surface: Color
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let dark = scheme == .dark
        content
            .background(surface)
            .clipShape(TerminalCard.shape)
            .overlay(TerminalCard.shape.strokeBorder(Color.primary.opacity(0.08)))
            .overlay {
                if dark {
                    TerminalCard.shape.strokeBorder(TerminalCard.topLight)
                        // The top edge and the corners' turn, fading into
                        // the plain hairline down the sides. A hard stop
                        // showed as a step beside the tab row.
                        .mask(alignment: .top) {
                            LinearGradient(stops: [.init(color: .black, location: 0),
                                                   .init(color: .black, location: 0.25),
                                                   .init(color: .clear, location: 1)],
                                           startPoint: .top, endPoint: .bottom)
                                .frame(height: TabChipMetrics.rowHeight + TerminalCard.radius)
                        }
                        .allowsHitTesting(false)
                }
            }
            .background {
                TerminalCard.shape
                    .fill(surface)
                    .shadow(color: .black.opacity(dark ? 0.32 : 0.09), radius: 7, y: 3)
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    /// Draws this as the card the tab bar sits on.
    func canvasCard(surface: Color = TerminalTheme.shared.canvas) -> some View {
        modifier(CanvasCard(surface: surface))
    }
}

private struct TabBar: View {
    @Environment(AppStore.self) private var store
    @Environment(TerminalManager.self) private var terminals
    @Environment(TabShortcuts.self) private var shortcuts
    let project: Project
    /// The tab (or pair, by its first tab) being dragged along the bar.
    @State private var dragging: UUID?

    /// "bun run dev" when the project has a dev script and the button is on.
    private var devCommand: String? {
        shortcuts.showsDevButton ? PackageManager.devCommand(in: project.url) : nil
    }

    /// Opens a tab running `command`, or switches to one still running it.
    private func run(_ command: String, reuse: Bool) {
        if reuse, let existing = project.tabs.last(where: { $0.command == command }), terminals.isRunning(existing.id) {
            store.selectTab(existing.id, in: project.id)
        } else {
            store.addTab(.shell, to: project.id, command: command)
        }
    }

    private func tabButton(_ tab: TabRecord, inSelectedSplit: Bool, embedded: Bool = false) -> some View {
        let starting = store.showsStartPage(project)
        return TabButton(
            tab: tab,
            projectID: project.id,
            session: terminals.existingSession(tab.id),
            isSelected: !starting && tab.id == project.selectedTab?.id,
            // In a pair, only the half you're in (or under the pointer)
            // shows its close button.
            showsClose: inSelectedSplit && !embedded,
            embedded: embedded,
            select: { store.selectTab(tab.id, in: project.id) },
            close: { close(tab) },
            isEdited: project.fileURL(of: tab).map(FileDrafts.shared.isEdited) ?? false
        )
        .contextMenu { TabMenu(project: project, tab: tab, close: { close(tab) }, closeTabs: close) }
    }

    private func close(_ tab: TabRecord) {
        guard FileDrafts.shared.confirmLosing([project.fileURL(of: tab)].compactMap { $0 }) else { return }
        if terminals.confirmClose(tab) { store.closeTab(tab.id, in: project.id) }
    }

    /// Closes several tabs, asking once if any of them is busy.
    private func close(_ tabs: [TabRecord]) {
        guard !tabs.isEmpty, FileDrafts.shared.confirmLosing(tabs.compactMap(project.fileURL(of:))),
              terminals.confirmClose(tabs) else { return }
        for tab in tabs { store.closeTab(tab.id, in: project.id) }
    }

    var body: some View {
        let starting = store.showsStartPage(project)
        TabRow {
            CardBandLeading()
        } tabs: {
            ForEach(project.tabStops) { tab in
                Group {
                if let split = project.split(of: tab.id),
                   let second = project.tabs.first(where: { $0.id == split.second }) {
                    let selected = !starting && [split.first, split.second].contains(project.selectedTab?.id)
                    SplitTabPair(axis: split.axis, isOpen: selected) { axis in
                        store.setSplitAxis(axis, of: tab.id, in: project.id)
                    } swap: {
                        store.swapSplit(of: tab.id, in: project.id)
                    } separate: {
                        store.unsplit(tab.id, in: project.id)
                    } first: {
                        tabButton(tab, inSelectedSplit: selected, embedded: true)
                    } second: {
                        tabButton(second, inSelectedSplit: selected, embedded: true)
                    }
                } else {
                    tabButton(tab, inSelectedSplit: false)
                }
                }
                .modifier(TabDrag(tabID: tab.id, projectID: project.id, dragging: $dragging, store: store))
                .transition(TabTransition())
            }
            if starting, !project.tabs.isEmpty {
                TabChip(symbol: "plus.square", tint: .secondary, title: "New Tab", isSelected: true, showsClose: true,
                        help: "Close the New Tab page to go back to the tab you were on",
                        select: {}, close: { store.closeStartPage(project.id) }) { EmptyView() }
                    .transition(TabTransition())
            }
        } trailing: {
            NewTabMenu(project: project, devCommand: devCommand, run: run)
        } end: {
            // The open tab as a terminal or a chat, at the end of the row
            // so it stays put as tabs come and go.
            if !starting, let tab = project.selectedTab, tab.kind == .agent,
               terminals.existingSession(tab.id)?.remoteHost == nil {
                ChatToggle(showsChat: tab.showsChat == true) { showsChat in
                    withAnimation(Theme.Motion.layout) { store.setShowsChat(showsChat, tab: tab.id, in: project.id) }
                }
            }
            CardBandTrailing()
        }
        // On the row, not the ForEach, so tabs coming and going are
        // animated, not just the ones that stay.
        .animation(Theme.Motion.tab, value: project.tabStops.map(\.id))
        .animation(Theme.Motion.tab, value: starting)
        // Another project's tabs replace these outright rather than
        // animating in.
        .id(project.id)
    }
}

/// Lets a tab be dragged along the tab bar, the others making way as it
/// passes them. A split pair moves as one.
private struct TabDrag: ViewModifier {
    let tabID: UUID
    let projectID: UUID
    @Binding var dragging: UUID?
    let store: AppStore

    func body(content: Content) -> some View {
        content
            .onDrag {
                dragging = tabID
                return NSItemProvider(object: tabID.uuidString as NSString)
            }
            .onDrop(of: [.text], delegate: TabReorderDelegate(target: tabID, projectID: projectID, dragging: $dragging, store: store))
    }
}

private struct TabReorderDelegate: DropDelegate {
    let target: UUID
    let projectID: UUID
    @Binding var dragging: UUID?
    let store: AppStore

    func validateDrop(info: DropInfo) -> Bool { dragging != nil }

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        store.moveTab(dragging, over: target, in: projectID)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

/// ＋ right after the last tab. A click opens a new Claude tab; the arrow
/// beside it lists other new tabs, the project's shortcuts and past
/// sessions, which used to have buttons of their own in the bar. Another Mac's
/// project has the same button with the same items in the same order
/// (`remoteMenu` in RemoteProjectView), so keep the two in step.
private struct NewTabMenu: View {
    @Environment(AppStore.self) private var store
    @Environment(TabShortcuts.self) private var shortcuts
    @Environment(TerminalManager.self) private var terminals
    let project: Project
    let devCommand: String?
    let run: (String, Bool) -> Void

    private func isRunning(_ command: String) -> Bool {
        project.tabs.contains { $0.command == command && terminals.isRunning($0.id) }
    }

    private var accounts: ClaudeAccounts { ClaudeAccounts.shared }
    private var newTabAccount: ClaudeProfile { accounts.profile(store.claudeAccountID(for: project.id)) }

    private var help: String {
        let base = "New Tab (⌘T). Use the arrow to open one kind of tab directly, or for shortcuts and past sessions (⌘Y)"
        return accounts.hasSeveral ? "\(base). New tabs here use your \(newTabAccount.name) account." : base
    }

    var body: some View {
        @Bindable var store = store
        Menu {
            // Your usual agent first, then any other.
            let agents = [Agents.standard] + Agents.offered.filter { $0.id != Agents.standard.id }
            ForEach(agents, id: \.id) { agent in
                Button("New \(agent.name) Tab") { store.addTab(.agent, to: project.id, agent: agent.id) }
            }
            if accounts.hasSeveral {
                // A one-off tab on another account, without changing the project's.
                Menu("New Claude Tab As") {
                    ForEach(accounts.profiles) { profile in
                        Button(profile.name) {
                            store.addTab(.agent, to: project.id, account: profile.id, agent: .claude)
                        }
                    }
                }
            }
            Button("New Shell Tab") { store.addTab(.shell, to: project.id) }
            Button("New Browser Tab") { store.openBrowserTab(in: project.id) }
            Button("New Agent on a Branch…") { store.startNewAgent(from: project.id) }
            Button("New Tab Page") { store.openStartPage(project.id) }
            let list = shortcuts.shortcuts(for: project)
            if devCommand != nil || !list.isEmpty {
                Section("Shortcuts") {
                    if let dev = devCommand {
                        Button {
                            run(dev, true)
                        } label: {
                            Label(isRunning(dev) ? "\(dev) (running)" : dev, systemImage: "play.fill")
                        }
                    }
                    ForEach(list) { shortcut in
                        Button {
                            run(shortcut.command, shortcut.reusesRunningTab)
                        } label: {
                            Label(shortcut.reusesRunningTab && isRunning(shortcut.command) ? "\(shortcut.name) (running)" : shortcut.name,
                                  systemImage: shortcut.symbol)
                        }
                    }
                }
            }
            Divider()
            if ProjectAccountMenuItems.hasChoice {
                Menu(CodexAccountsGroup.hasChoice ? "New Tabs Use…" : "New Tabs Use: \(newTabAccount.name)") {
                    ProjectAccountMenuItems(projectID: project.id)
                }
            }
            Button("Past Sessions…") { store.showsHistory = true }
            Button("Edit Shortcuts…") { store.settingsSection = .shortcuts }
        } label: {
            Image(systemName: "plus")
                .font(.ui(size: 12, weight: .medium))
        } primaryAction: {
            // The New Tab page; from it, the button starts Claude.
            if store.showsStartPage(project) {
                store.addTab(.agent, to: project.id)
            } else {
                store.openStartPage(project.id)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .frame(height: BarButtonMetrics.height)
        // A project on another account says so, in that account's color.
        // The main account gets no mark, so a dot never reads as an alert
        // on every project.
        .overlay(alignment: .topLeading) {
            if accounts.hasSeveral, !newTabAccount.isMain {
                Circle()
                    .fill(AccountBadge.color(accounts.index(of: newTabAccount.id)))
                    .frame(width: 6, height: 6)
                    .offset(x: 17, y: 7)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel("New Tab")
        .accessibilityValue(accounts.hasSeveral ? newTabAccount.name : "")
        .help(help)
        .popover(isPresented: $store.showsHistory, arrowEdge: .bottom) {
            HistoryPopover(project: project) { store.showsHistory = false }
        }
    }
}

private struct TabButton: View {
    @Environment(PortScanner.self) private var scanner
    let tab: TabRecord
    let projectID: UUID
    let session: TerminalSession?
    let isSelected: Bool
    /// Keeps the close button showing, for the other side of the split
    /// you're in.
    var showsClose = false
    /// Half of a split pair, which draws the tab around both.
    var embedded = false
    let select: () -> Void
    let close: () -> Void
    /// A file tab with unsaved edits.
    var isEdited = false

    private var iconColor: Color {
        switch tab.kind {
        case .agent: .orange
        case .diff: .blue
        case .preview: .teal
        case .file: .indigo
        case .review: .purple
        case .shell: .secondary
        }
    }

    @Environment(AppStore.self) private var store

    /// For a Claude tab on a different account than the project's new tabs
    /// use: that account, so the tab can say so.
    private var otherAccount: ClaudeProfile? {
        let accounts = ClaudeAccounts.shared
        guard tab.kind == .agent, accounts.hasSeveral, session?.remoteHost == nil else { return nil }
        let mine = accounts.profile(tab.claudeAccountID)
        return mine.id == store.claudeAccountID(for: projectID) ? nil : mine
    }

    // The chip's pieces are worked out one at a time, each with its type
    // written down: all in one call they're more than older compilers can
    // type-check in the time they allow.

    private var symbol: String {
        if session?.remoteHost != nil { return "network" }
        return tab.diff?.isImage == true ? "photo" : tab.symbol
    }

    private var tint: Color {
        session?.remoteHost != nil ? ActivityBackground.remote : iconColor
    }

    private var help: String {
        if tab.isPreview {
            return "Preview: the next file you click replaces it. Right-click to keep it open."
        }
        if let host = session?.remoteHost { return "Logged in to \(host)" }
        return session?.terminalTitle ?? tab.diff?.path ?? tab.filePath ?? tab.displayTitle
    }

    private var rename: TabChipRename? {
        guard store.renamingTabID == tab.id else { return nil }
        return TabChipRename(placeholder: tab.title, name: tab.displayTitle) { name in
            guard store.renamingTabID == tab.id else { return }
            if let name { store.renameTab(tab.id, in: projectID, to: name) }
            store.renamingTabID = nil
        }
    }

    var body: some View {
        TabChip(
            symbol: symbol,
            tint: tint,
            // Just what the tab is ("Claude", a file name). The terminal
            // title, with what Claude is working on, is in the tooltip.
            title: tab.displayTitle,
            isSelected: isSelected,
            showsClose: showsClose,
            help: help,
            activity: session?.activity ?? .idle,
            isPreview: tab.isPreview,
            embedded: embedded,
            rename: rename,
            select: select,
            close: close
        ) {
            if isEdited {
                Circle()
                    .fill(Color.primary.opacity(0.55))
                    .frame(width: 6, height: 6)
                    .help("Unsaved changes")
                    .accessibilityLabel("Unsaved changes")
            }
            if let other = otherAccount {
                AccountBadge(name: other.name, index: ClaudeAccounts.shared.index(of: other.id), size: 12)
                    .help("This tab uses your \(other.name) account")
            }
            let ports = scanner.ports(forTab: tab.id)
            if !ports.isEmpty {
                PortsBadge(ports: ports, projectID: projectID)
            }
        }
    }
}

/// A tab's right-click menu: splitting it, and closing it or others.
private struct TabMenu: View {
    @Environment(AppStore.self) private var store
    let project: Project
    let tab: TabRecord
    let close: () -> Void
    let closeTabs: ([TabRecord]) -> Void

    /// The other tabs, and the ones after this one. The other half of a
    /// split stays with this tab.
    private var others: [TabRecord] {
        let partner = project.partner(of: tab.id)
        return project.tabs.filter { $0.id != tab.id && $0.id != partner }
    }

    private var toTheRight: [TabRecord] {
        guard let index = project.tabs.firstIndex(where: { $0.id == tab.id }) else { return [] }
        let partner = project.partner(of: tab.id)
        return project.tabs[(index + 1)...].filter { $0.id != partner }
    }

    var body: some View {
        if tab.canSplit {
            if let split = project.split(of: tab.id) {
                // The same items, in the same words, as the menu between
                // the two halves of the tab.
                Button("Side by Side") { store.setSplitAxis(.sideBySide, of: tab.id, in: project.id) }
                    .disabled(split.axis == .sideBySide)
                Button("Stacked") { store.setSplitAxis(.stacked, of: tab.id, in: project.id) }
                    .disabled(split.axis == .stacked)
                Button("Swap Sides") { store.swapSplit(of: tab.id, in: project.id) }
                Button("Unsplit") { store.unsplit(tab.id, in: project.id) }
            } else {
                if tab.isTerminal {
                    Button("Split Right") { store.splitTab(tab.id, in: project.id, axis: .sideBySide) }
                    Button("Split Down") { store.splitTab(tab.id, in: project.id, axis: .stacked) }
                }
                // A page pairs with a terminal or chat, not another page.
                let others = project.tabs.filter {
                    $0.id != tab.id && project.split(of: $0.id) == nil && (tab.isTerminal ? $0.canSplit : $0.isTerminal)
                }
                if !others.isEmpty {
                    Menu("Split With") {
                        ForEach(others) { other in
                            Button(other.displayTitle) {
                                // The page goes on the right, the chat keeps the keys.
                                if tab.isTerminal { store.pairTabs(tab.id, with: other.id, in: project.id) }
                                else { store.pairTabs(other.id, with: tab.id, in: project.id) }
                            }
                        }
                    }
                }
            }
            Divider()
        }
        if tab.isPreview {
            Button("Keep Open") { store.keepTab(tab.id, in: project.id) }
        }
        Button("Rename Tab\u{2026}") { store.renamingTabID = tab.id }
        if tab.customTitle != nil {
            Button("Use Default Name") { store.renameTab(tab.id, in: project.id, to: nil) }
        }
        Divider()
        Button("Close Tab", action: close)
        Button("Close Other Tabs") { closeTabs(others) }
            .disabled(others.isEmpty)
        Button("Close Tabs to the Right") { closeTabs(toTheRight) }
            .disabled(toTheRight.isEmpty)
        Button("Close All Tabs") { closeTabs(project.tabs) }
    }
}

/// Switches the Claude tab you're in between its terminal and the
/// conversation. It sits at the end of the tab row. Drawn in SwiftUI: a segmented Picker is a real NSSegmentedControl,
/// which fought the window over its width.
private struct ChatToggle: View {
    let showsChat: Bool
    let set: (Bool) -> Void
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 0) {
            segment("Terminal", symbol: "terminal", isOn: !showsChat, help: "Show the terminal (⌥⌘T)") { set(false) }
            segment("Chat", symbol: "bubble.left", isOn: showsChat, help: "Show as a chat (⌥⌘T)") { set(true) }
        }
        .padding(2)
        .background(Theme.Fill.subtle, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.Fill.hairline))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("View")
        .accessibilityValue(showsChat ? "Chat" : "Terminal")
    }

    private func segment(_ label: String, symbol: String, isOn: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            // Marks rather than words, so the room goes to the tabs.
            Image(systemName: symbol)
                .font(.ui(size: Theme.TypeScale.meta, weight: .medium))
                .frame(width: 28)
                .foregroundStyle(isOn ? Color.primary : Color.secondary)
                .frame(height: 22)
                .background {
                    // One pill that slides to whichever side is on.
                    if isOn {
                        Capsule()
                            .fill(Theme.Fill.selected)
                            .matchedGeometryEffect(id: "selection", in: selection)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.pressable)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}
