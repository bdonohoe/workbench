import BenchKit
import SwiftUI

/// Send one message to several projects from the phone. The Mac splits it
/// into tasks, you check and edit them here, then the Mac starts an agent
/// for each on its own branch. Dictation is the keyboard's: tap its mic.
struct SendTasksView: View {
    @Environment(CompanionClient.self) private var client
    @Environment(\.dismiss) private var dismiss

    private enum Step { case write, splitting, review, starting }

    @State private var step = Step.write
    @State private var message = ""
    @State private var tasks: [DraftTask] = []
    @State private var projects: [SplitProject] = []
    @State private var existing: [UUID: Set<String>] = [:]
    @State private var startFailures: [UUID: String] = [:]
    @State private var splitProblem: String?
    /// Why the last Start didn't go, when the phone found out on its own.
    @State private var startProblem: String?
    @FocusState private var messageFocused: Bool

    private var names: [UUID: String] {
        Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.name) })
    }

    private var problems: [UUID: String] {
        TaskSplit.problems(tasks, existing: existing, names: names)
    }

    private var canStart: Bool { !tasks.isEmpty && problems.isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch step {
                    case .write, .splitting: write
                    case .review, .starting: review
                    }
                }
                .padding(16)
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(PhoneTheme.canvas)
            .navigationTitle("Brain Dump")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(step == .starting)
                }
            }
            .interactiveDismissDisabled(step == .starting)
        }
        .onAppear { messageFocused = true }
        .onDisappear { client.clearTaskSplit() }
        .onChange(of: client.taskSplit) { _, result in
            guard step == .splitting, let result else { return }
            if let problem = result.problem {
                splitProblem = problem
                step = .write
            } else {
                tasks = result.tasks
                projects = result.projects
                existing = result.existingBranches.mapValues(Set.init)
                startFailures = [:]
                startProblem = nil
                step = .review
            }
        }
        .onChange(of: client.taskStartFailures) { _, failures in
            guard step == .starting, let failures else { return }
            if failures.isEmpty {
                dismiss()
            } else {
                tasks.removeAll { failures[$0.id] == nil }
                startFailures = failures
                step = .review
            }
        }
        .onChange(of: client.lastProblem) { _, problem in
            // The Mac couldn't take the request at all.
            guard let problem else { return }
            if step == .splitting { splitProblem = problem; step = .write }
            if step == .starting { step = .review }
        }
        .onChange(of: client.status) { _, status in
            guard status != .connected else { return }
            // The answer isn't coming: an unanswered step would lock the sheet.
            if step == .splitting { splitProblem = "Lost the Mac while splitting. Try again."; step = .write }
            if step == .starting { startProblem = "Lost the Mac while starting. Check Workbench before trying again."; step = .review }
        }
        // Any edit makes a task's last start error out of date.
        .onChange(of: tasks) { old, new in
            for task in new where old.first(where: { $0.id == task.id }) != task { startFailures[task.id] = nil }
        }
        #if DEBUG
        // For testing without typing: BENCH_SEND_TASKS_MESSAGE=<text> fills
        // the message in, BENCH_SEND_TASKS_AUTO=split splits it right away,
        // and =start also starts the agents once the split is back.
        .task {
            let env = ProcessInfo.processInfo.environment
            // BENCH_SEND_TASKS_SAMPLE=1 shows sample tasks for the demo
            // projects, for screenshots without a Mac.
            if env["BENCH_SEND_TASKS_SAMPLE"] != nil {
                try? await Task.sleep(for: .seconds(0.5))
                let demo = rootProjects
                projects = demo.map { SplitProject(id: $0.id, name: $0.name, summary: "") }
                message = "Recipes needs a shopping list built from the week's meals. The RSS feed on the website shows every post as published today, fix that. And the reading app needs a font size slider in settings."
                tasks = [
                    DraftTask(projectID: demo.first?.id, prompt: "Add a shopping list built from a week of recipes. Combine matching ingredients, group them by aisle, and let me check items off.", source: "Recipes needs a shopping list built from the week's meals", branch: "feat/shopping-list"),
                    DraftTask(projectID: demo.dropFirst().first?.id, prompt: "The RSS feed shows every post as published today. Use each post's own date in the feed, and add a test that checks two posts with different dates.", source: "The RSS feed on the website shows every post as published today", branch: "fix/rss-dates"),
                    DraftTask(unsure: "Could be read-later or quick-reads-ios.", prompt: "Add a font size slider to the settings screen. It should change the article text size live as you drag, and remember the choice.", source: "the reading app needs a font size slider", branch: "feat/font-size-slider"),
                ]
                step = env["BENCH_SEND_TASKS_SAMPLE"] == "write" ? .write : .review
                return
            }
            guard let text = env["BENCH_SEND_TASKS_MESSAGE"] else { return }
            message = text
            guard let auto = env["BENCH_SEND_TASKS_AUTO"] else { return }
            try? await Task.sleep(for: .seconds(1))
            split()
            guard auto == "start" else { return }
            while step == .splitting { try? await Task.sleep(for: .seconds(0.5)) }
            guard step == .review, canStart else { return }
            try? await Task.sleep(for: .seconds(2))
            startFailures = [:]
            step = .starting
            client.startTasks(tasks)
        }
        #endif
    }

    // MARK: Write

    @ViewBuilder private var write: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("What should your agents work on?")
                .font(.title3.weight(.semibold))
                .foregroundStyle(PhoneTheme.ink)
            Text("Say what you want done across your projects, and name the project each thing is for. You'll check the split before anything starts.")
                .font(.subheadline)
                .foregroundStyle(PhoneTheme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }

        TextField("Tap the mic on the keyboard to dictate", text: $message, axis: .vertical)
            .lineLimit(6...16)
            .focused($messageFocused)
            .disabled(step == .splitting)
            .padding(12)
            .flatCard(outline: messageFocused ? PhoneTheme.ink.opacity(0.3) : PhoneTheme.hairline)

        if let splitProblem {
            Text(splitProblem)
                .font(.subheadline)
                .foregroundStyle(PhoneTheme.error)
        }

        if !rootProjects.isEmpty {
            ProjectIconGrid(projects: rootProjects, icons: client.icons)
        }

        Button(action: split) {
            HStack(spacing: 8) {
                if step == .splitting { ProgressView() }
                Text(step == .splitting ? "Matching projects…" : "Split into Tasks")
            }
        }
        .buttonStyle(.phonePrimary)
        .disabled(step == .splitting || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// Your projects, not their worktrees: where tasks can go.
    private var rootProjects: [CompanionProject] {
        client.snapshot?.projects.filter { $0.parentID == nil } ?? []
    }

    private func split() {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        splitProblem = nil
        step = .splitting
        messageFocused = false
        client.splitTasks(message: text)
    }

    // MARK: Review

    @ViewBuilder private var review: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tasks.count == 1 ? "1 task" : "\(tasks.count) tasks")
                .font(.title3.weight(.semibold))
                .foregroundStyle(PhoneTheme.ink)
            Text("Each gets its own branch, worktree and agent tab on the Mac. Prompts are sent exactly as written.")
                .font(.subheadline)
                .foregroundStyle(PhoneTheme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }

        // What you asked. Changing it means the Mac splits it again.
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(ToolWording.oneLine(message))
                    .lineLimit(2)
            } icon: {
                Image(systemName: "text.bubble")
            }
            .font(.subheadline)
            .foregroundStyle(PhoneTheme.inkMuted)
            Button { step = .write } label: { Text("Change and Split Again").touchArea(vertical: 12) }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(PhoneTheme.accent)
                .disabled(step == .starting)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PhoneTheme.raised, in: RoundedRectangle(cornerRadius: PhoneTheme.Radius.card, style: .continuous))

        if tasks.isEmpty {
            Text("No tasks found. Change your message and split again, or add a task.")
                .font(.subheadline)
                .foregroundStyle(PhoneTheme.inkMuted)
                .frame(maxWidth: .infinity, minHeight: 80)
        }

        ForEach($tasks) { $task in
            TaskCard(task: $task, projects: projects, snapshot: client.snapshot, icons: client.icons,
                     problem: problems[task.id], startFailure: startFailures[task.id]) {
                withAnimation(.snappy) {
                    tasks.removeAll { $0.id == task.id }
                    startFailures[task.id] = nil
                }
            }
            .disabled(step == .starting)
        }

        Button {
            withAnimation(.snappy) { tasks.append(DraftTask()) }
        } label: {
            Label("Add a Task", systemImage: "plus")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(PhoneTheme.inkMuted)
                .touchArea(vertical: 12)
        }
        .buttonStyle(.plain)
        .disabled(step == .starting)

        if let problem = startProblem ?? client.lastProblem, step == .review {
            Text(problem)
                .font(.subheadline)
                .foregroundStyle(PhoneTheme.error)
        }

        Button {
            startFailures = [:]
            startProblem = nil
            step = .starting
            client.startTasks(tasks)
        } label: {
            HStack(spacing: 8) {
                if step == .starting { ProgressView() }
                Text(tasks.count == 1 ? "Start 1 Agent" : "Start \(tasks.count) Agents")
            }
        }
        .buttonStyle(.phonePrimary)
        .disabled(step == .starting || !canStart)
    }
}

/// One task, editable in place: a header with its project, then the full
/// prompt, then its branch. On an iPad the branch sits in the header, as
/// on the Mac.
private struct TaskCard: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Binding var task: DraftTask
    let projects: [SplitProject]
    let snapshot: ProjectsSnapshot?
    let icons: [UUID: Data]
    let problem: String?
    let startFailure: String?
    let remove: () -> Void
    @FocusState private var focus: Field?

    private enum Field { case branch, prompt }

    var body: some View {
        let needsProject = task.projectID == nil
        let wide = sizeClass == .regular
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                projectMenu(needsProject: needsProject)
                Spacer(minLength: 8)
                if wide { branchField.frame(maxWidth: 240) }
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(PhoneTheme.inkMuted)
                        .frame(width: 32, height: 32)
                        .touchArea(horizontal: 6, vertical: 6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove task")
            }
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .padding(.vertical, 4)
            .background(needsProject ? PhoneTheme.waiting.opacity(0.14) : PhoneTheme.raised)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if needsProject, let unsure = task.unsure, !unsure.isEmpty {
                    Text(unsure)
                        .font(.footnote)
                        .foregroundStyle(PhoneTheme.waiting)
                }
                // A task with no project says so in its amber header.
                ForEach([needsProject ? nil : problem, startFailure].compactMap { $0 }, id: \.self) { line in
                    Text(line)
                        .font(.footnote)
                        .foregroundStyle(PhoneTheme.error)
                }
                TextField("What should the agent do?", text: $task.prompt, axis: .vertical)
                    .lineLimit(2...)
                    .foregroundStyle(PhoneTheme.ink)
                    .focused($focus, equals: .prompt)
                if !wide { branchField }
                TaskSourceLine(source: task.source)
                    .font(.footnote)
            }
            .padding(12)
        }
        .flatCard(outline: needsProject ? PhoneTheme.waiting.opacity(0.5)
                  : focus != nil ? PhoneTheme.ink.opacity(0.35) : PhoneTheme.hairline,
                  width: focus != nil ? 1.5 : 1)
        .animation(.easeOut(duration: 0.12), value: focus)
    }

    private func projectMenu(needsProject: Bool) -> some View {
        Menu {
            Picker("Project", selection: Binding(
                get: { task.projectID },
                set: { task.projectID = $0; task.unsure = nil }
            )) {
                ForEach(projects, id: \.id) { project in
                    Text(project.name).tag(UUID?.some(project.id))
                }
            }
        } label: {
            HStack(spacing: 8) {
                if let project {
                    CompanionProjectIcon(project: project, icon: icons[project.id], size: 22)
                } else {
                    UnassignedProjectIcon(size: 22, color: PhoneTheme.waiting)
                }
                Text(name ?? "Which project?")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(needsProject ? PhoneTheme.waiting : PhoneTheme.ink)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(PhoneTheme.inkMuted)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var branchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .font(.caption)
                .foregroundStyle(PhoneTheme.inkMuted)
            TextField("feat/my-change", text: $task.branch)
                .font(.footnote.monospaced())
                .foregroundStyle(PhoneTheme.ink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focus, equals: .branch)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(PhoneTheme.canvas, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(focus == .branch ? PhoneTheme.ink.opacity(0.3) : PhoneTheme.hairline))
    }

    private var project: CompanionProject? {
        task.projectID.flatMap { id in snapshot?.projects.first { $0.id == id } }
    }

    private var name: String? {
        task.projectID.flatMap { id in projects.first { $0.id == id }?.name ?? project?.name }
    }
}

/// Every project Claude can choose from, as icons to look through while
/// you decide what to work on. Tapping one shows its name, since there's no
/// hover on a phone.
private struct ProjectIconGrid: View {
    let projects: [CompanionProject]
    let icons: [UUID: Data]
    @State private var selected: UUID?

    private let iconSize: CGFloat = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let name = projects.first { $0.id == selected }?.name
            Text(name ?? "Your agent picks from these")
                .font(.caption.weight(name == nil ? .regular : .semibold))
                .foregroundStyle(name == nil ? PhoneTheme.inkMuted : PhoneTheme.ink)
                .lineLimit(1)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: iconSize, maximum: iconSize), spacing: 10)],
                      alignment: .leading, spacing: 10) {
                ForEach(projects, id: \.id) { project in
                    Button {
                        selected = selected == project.id ? nil : project.id
                    } label: {
                        CompanionProjectIcon(project: project, icon: icons[project.id], size: iconSize)
                            // Reaches a little past the icon, for a fingertip.
                            .padding(5)
                            .contentShape(Rectangle())
                            .padding(-5)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(project.name)
                }
            }
        }
    }
}

private extension View {
    /// A surface with a hairline edge and no shadow.
    func flatCard(outline: Color, width: CGFloat = 1) -> some View {
        background(PhoneTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: PhoneTheme.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: PhoneTheme.Radius.card, style: .continuous).strokeBorder(outline, lineWidth: width))
    }
}
