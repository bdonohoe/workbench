import BenchKit
import SwiftUI

/// Splits one message into tasks across your projects, lets you check and
/// edit them, then starts an agent for each.
struct SendTasksSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(TerminalManager.self) private var terminals
    @Environment(\.dismiss) private var dismiss
    @State private var model: SendTasksModel
    @State private var listHeight: CGFloat = 0
    @FocusState private var messageFocused: Bool

    init(model: SendTasksModel = SendTasksModel()) {
        _model = State(initialValue: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch model.step {
            case .write, .splitting: write
            case .review, .starting: review
            }
        }
        .padding(20)
        .frame(width: 620)
        .interactiveDismissDisabled(model.step == .starting)
        .onAppear {
            model.load(from: store)
            messageFocused = true
        }
        .onChange(of: model.step) { _, step in
            if step == .write { messageFocused = true }
        }
        .onDisappear { model.cancelSplit() }
        .modifier(RemoteReplies(model: model))
    }

    // MARK: Write

    @ViewBuilder private var write: some View {
        SheetHeader(title: model.remote.map { "Brain Dump on \($0.macName ?? "the Other Mac")" } ?? "Brain Dump",
                    detail: "Say what you want done across your projects. You'll check the split before anything starts.")

        TextEditor(text: $model.message)
            .font(.ui(size: 13))
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(height: 170)
            .flatField(focused: messageFocused)
            .focused($messageFocused)
            .tabMovesFocus()
            .disabled(model.step == .splitting)

        if let error = model.error {
            Text(error)
                .font(.ui(size: 12))
                .foregroundStyle(Theme.Status.failed)
                .fixedSize(horizontal: false, vertical: true)
        }

        ProjectIconGrid(projects: model.projects, remote: model.remote)

        HStack(spacing: 6) {
            if model.step == .splitting {
                ProgressView().controlSize(.small)
                Text("Reading your message and matching projects…")
                    .font(.ui(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Split into Tasks") { model.split() }
                .buttonStyle(.prominent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.step == .splitting
                          || model.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    // MARK: Review

    @ViewBuilder private var review: some View {
        SheetHeader(title: model.tasks.count == 1 ? "1 task" : "\(model.tasks.count) tasks",
                    detail: "Each gets its own branch, worktree and agent tab. Prompts are sent exactly as written.")

        // What you asked. Changing it means Claude splits it again.
        HStack(spacing: 8) {
            Image(systemName: "text.bubble")
                .font(.ui(size: 11))
                .foregroundStyle(.tertiary)
            Text(ToolWording.oneLine(model.message))
                .font(.ui(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(model.message)
            Spacer(minLength: 8)
            Button("Change and Split Again") { model.editMessage() }
                .buttonStyle(.link)
                .font(.ui(size: 12))
                .disabled(model.step == .starting)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.04)))

        if model.tasks.isEmpty {
            Text("No tasks found. Change your message and split again, or add a task.")
                .font(.ui(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 80)
        } else {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(model.tasks) { task in
                        TaskCard(task: binding(for: task.id), model: model)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }
            .frame(height: min(max(listHeight, 1), 540))
            .disabled(model.step == .starting)
        }

        if let error = model.error {
            Text(error)
                .font(.ui(size: 12))
                .foregroundStyle(Theme.Status.failed)
                .fixedSize(horizontal: false, vertical: true)
        }

        HStack {
            Button {
                model.addTask()
            } label: {
                Label("Add a Task", systemImage: "plus")
            }
            .buttonStyle(.pressable)
            .foregroundStyle(.secondary)
            .disabled(model.step == .starting)
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(model.step == .starting)
            Button(action: start) {
                if model.step == .starting {
                    ProgressView().controlSize(.small)
                } else {
                    Text(model.tasks.count == 1 ? "Start 1 Agent" : "Start \(model.tasks.count) Agents")
                }
            }
            .buttonStyle(.prominent)
            // ⌘↩, not Return: Return in a field mustn't start agents.
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(model.step == .starting || !model.canStart)
        }
    }

    /// Looks the task up by id, so a field committing after its card is
    /// removed writes nothing instead of hitting a stale index.
    private func binding(for id: UUID) -> Binding<DraftTask> {
        Binding(
            get: { model.tasks.first { $0.id == id } ?? DraftTask(id: id) },
            set: { task in
                guard let index = model.tasks.firstIndex(where: { $0.id == id }) else { return }
                model.tasks[index] = task
            }
        )
    }

    private func start() {
        Task {
            if await model.start(store: store, terminals: terminals) { dismiss() }
        }
    }
}

/// One task, editable in place: a header with its project and branch, then
/// the full prompt, which grows to fit.
private struct TaskCard: View {
    @Environment(AppStore.self) private var store
    @Environment(ProjectIcons.self) private var icons
    @Binding var task: DraftTask
    let model: SendTasksModel
    @FocusState private var focus: Field?

    private enum Field { case branch, prompt }

    var body: some View {
        let needsProject = task.projectID == nil
        VStack(alignment: .leading, spacing: 0) {
            header(needsProject: needsProject)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                if needsProject, let unsure = task.unsure, !unsure.isEmpty {
                    Text(unsure)
                        .font(.ui(size: 12))
                        .foregroundStyle(ActivityBackground.waiting)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // A task with no project says so in its amber header.
                ForEach([needsProject ? nil : model.problems[task.id], model.startErrors[task.id]].compactMap { $0 }, id: \.self) { line in
                    Text(line)
                        .font(.ui(size: 12))
                        .foregroundStyle(Theme.Status.failed)
                        .fixedSize(horizontal: false, vertical: true)
                }
                GrowingTextEditor(text: $task.prompt, placeholder: "What should the agent do?")
                    .focused($focus, equals: .prompt)
                    // The editor insets its text; line it up with the rest.
                    .padding(.horizontal, -5)
                TaskSourceLine(source: task.source)
                    .font(.ui(size: 11))
            }
            .padding(10)
            .background(Color(nsColor: .textBackgroundColor).opacity(focus == .prompt ? 1 : 0))
            .contentShape(Rectangle())
            .onTapGesture { focus = .prompt }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(needsProject ? ActivityBackground.waiting.opacity(0.5)
                          : focus != nil ? Color.primary.opacity(0.4) : Color.primary.opacity(0.12),
                          lineWidth: focus != nil ? 1.5 : 1))
        .animation(.easeOut(duration: 0.12), value: focus)
        // Any edit makes the last start error out of date.
        .onChange(of: task) { model.startErrors[task.id] = nil }
    }

    private func header(needsProject: Bool) -> some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(model.projects, id: \.id) { project in
                    Button {
                        model.setProject(project.id, for: task.id)
                    } label: {
                        if project.id == task.projectID {
                            Label(project.name, systemImage: "checkmark")
                        } else {
                            Text(project.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    icon
                    Text(name ?? "Which project?")
                        .font(.ui(size: Theme.TypeScale.ui, weight: .semibold))
                        .foregroundStyle(needsProject ? AnyShapeStyle(ActivityBackground.waiting) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.ui(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Choose the project")
            Spacer(minLength: 8)
            Image(systemName: "arrow.triangle.branch")
                .font(.ui(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
            TextField("feat/my-change", text: $task.branch)
                .textFieldStyle(.plain)
                .font(.ui(size: Theme.TypeScale.meta, design: .monospaced))
                .focused($focus, equals: .branch)
                .frame(width: 190)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .flatField(focused: focus == .branch)
            Button {
                model.remove(task.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.ui(size: 10, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .foregroundStyle(.secondary)
            .help("Remove task")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(needsProject ? ActivityBackground.waiting.opacity(0.14) : Color.primary.opacity(0.045))
    }

    private var project: Project? {
        task.projectID.flatMap { id in store.projects.first { $0.id == id } }
    }

    private var name: String? {
        task.projectID.flatMap { id in model.projects.first { $0.id == id }?.name }
    }

    @ViewBuilder private var icon: some View {
        if let remote = model.remote, let id = task.projectID,
           let project = remote.snapshot?.projects.first(where: { $0.id == id }) {
            CompanionProjectIcon(project: project, icon: remote.icons[id], size: 18)
        } else if model.remote == nil, let project {
            ProjectIcon(project: project, image: icons.image(for: project), size: 18)
        } else {
            UnassignedProjectIcon(size: 18, color: ActivityBackground.waiting)
        }
    }
}

/// A plain text editor that grows with its text instead of scrolling, so a
/// prompt always shows in full.
private struct GrowingTextEditor: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Sizes the editor: the same text, laid out the same way.
            Text(text.isEmpty ? " " : text + " ")
                .font(.ui(size: 13))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 5)
                .hidden()
            if text.isEmpty {
                Text(placeholder)
                    .font(.ui(size: 13))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(.ui(size: 13))
                .lineSpacing(2)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .tabMovesFocus()
        }
    }
}

/// Every project Claude can choose from, as icons to look through while
/// you decide what to work on. Hovering one shows its name right away, with
/// no wait for a tooltip, so you can run along the row.
private struct ProjectIconGrid: View {
    @Environment(AppStore.self) private var store
    @Environment(ProjectIcons.self) private var icons
    let projects: [SplitProject]
    var remote: CompanionClient?
    @State private var hovered: UUID?

    private let iconSize: CGFloat = 24

    var body: some View {
        let shown = projects.filter { project in
            remote == nil ? store.projects.contains { $0.id == project.id }
                : remote?.snapshot?.projects.contains { $0.id == project.id } == true
        }
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                let name = shown.first { $0.id == hovered }?.name
                Text(name ?? "Your agent picks from these")
                    .font(.ui(size: 11, weight: name == nil ? .regular : .medium))
                    .foregroundStyle(name == nil ? Color.secondary : Color.primary)
                    .lineLimit(1)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: iconSize, maximum: iconSize), spacing: 5)],
                          alignment: .leading, spacing: 5) {
                    ForEach(shown, id: \.id) { project in
                        icon(for: project.id)
                            .accessibilityElement()
                            .accessibilityLabel(project.name)
                            .onHover { inside in
                                if inside {
                                    hovered = project.id
                                } else if hovered == project.id {
                                    // The next icon may have already taken over.
                                    hovered = nil
                                }
                            }
                    }
                }
            }
        }
    }

    @ViewBuilder private func icon(for id: UUID) -> some View {
        if let remote, let project = remote.snapshot?.projects.first(where: { $0.id == id }) {
            CompanionProjectIcon(project: project, icon: remote.icons[id], size: iconSize)
        } else if let project = store.projects.first(where: { $0.id == id }) {
            ProjectIcon(project: project, image: icons.image(for: project), size: iconSize)
        }
    }
}

/// Feeds the other Mac's answers into a remote model, and closes the sheet
/// once every agent has started there.
private struct RemoteReplies: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    let model: SendTasksModel

    func body(content: Content) -> some View {
        if let remote = model.remote {
            content
                .onChange(of: remote.taskSplit) { _, result in
                    if let result { model.receive(result) }
                }
                .onChange(of: remote.taskStartFailures) { _, failures in
                    if let failures, model.receive(failures: failures) { dismiss() }
                }
                .onChange(of: remote.lastProblem) { _, problem in
                    if let problem { model.remoteFailed(problem) }
                }
                .onChange(of: remote.status) { _, status in
                    if status != .connected { model.remoteFailed("Lost the connection to the other Mac. Try again.") }
                }
        } else {
            content
        }
    }
}

#if DEBUG
/// The sheet with sample tasks for your real projects, drawn to PNGs in
/// light and dark. BENCH_RENDER_SENDTASKS_SHEET=<folder>.
enum SendTasksSheetPreview {
    static func render(to folder: URL) {
        _ = NSApplication.shared
        let store = AppStore()
        let terminals = TerminalManager(store: store)
        let icons = ProjectIcons()
        let roots = store.projects.filter { !$0.isWorktree }
        roots.forEach(icons.reload)
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        let picks = Array(roots.prefix(3))
        func sample(_ step: SendTasksModel.Step) -> SendTasksModel {
            let model = SendTasksModel()
            model.load(from: store)
            model.message = "Add a lap delta chart to the race view. The sidebar flickers when a tab finishes, can you fix that? And the reading app needs a font size slider in settings."
            model.step = step
            model.tasks = [
                DraftTask(projectID: picks.first?.id, prompt: "Add a lap delta chart to the race view. For each driver, plot the gap to the leader's lap time on every lap, so you can see who's gaining and who's fading. Put it under the lap times table.", source: "add a lap delta chart to the race view", branch: "feat/lap-delta-chart"),
                DraftTask(projectID: picks.dropFirst().first?.id, prompt: "The sidebar flickers when an agent tab finishes. Find what redraws the whole list at that moment and make the change animate in place instead.", source: "The sidebar flickers when a tab finishes", branch: "fix/sidebar-flicker"),
                DraftTask(unsure: "Could be read-later or quick-reads-ios.", prompt: "Add a font size slider to the settings screen. It should change the article text size live as you drag, and remember the choice.", source: "the reading app needs a font size slider", branch: "feat/font-size-slider"),
            ]
            return model
        }
        for (step, label) in [(SendTasksModel.Step.write, "write"), (.review, "review")] {
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let view = SendTasksSheet(model: sample(step))
                    .environment(store).environment(terminals).environment(icons)
                    .background(Color(nsColor: .windowBackgroundColor))
                let host = NSHostingView(rootView: view)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 900), styleMask: [.borderless],
                                      backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearance)
                window.contentView = host
                host.setFrameSize(host.fittingSize)
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(1))
                host.setFrameSize(host.fittingSize)
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("sheet-\(label)-\(name).png"))
            }
        }
    }
}
#endif
