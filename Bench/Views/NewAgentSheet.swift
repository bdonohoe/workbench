import BenchKit
import SwiftUI

/// Starts a Claude agent on its own branch: makes a git worktree for the
/// project, then opens a Claude tab there with your first prompt.
struct NewAgentSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(TerminalManager.self) private var terminals
    @Environment(\.dismiss) private var dismiss
    let parent: Project

    @State private var prompt = ""
    @State private var branch = ""
    /// Once you type a branch name, the prompt stops suggesting one.
    @State private var branchEdited = false
    @State private var base = ""
    @State private var branches: [String] = []
    @State private var isCreating = false
    @State private var error: String?
    /// Setup for the new worktree, saved on the project for next time.
    @State private var setupFiles = ""
    @State private var setupCommand = ""
    @State private var showsSetup = false
    /// The repo's open GitHub issues. None until `gh` answers, and none
    /// for a repo that isn't on GitHub.
    @State private var issues: [GitHubIssue] = []
    /// The issue this agent starts from, which wrote the prompt and branch.
    @State private var issue: GitHubIssue?
    @State private var showsIssues = false
    /// Which agent does the work, when there's more than one to choose.
    @State private var agent = Agents.standard.id
    @FocusState private var promptFocused: Bool

    private var agentName: String { Agents.provider(agent)?.name ?? Agents.standard.name }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: "New Agent in \(parent.name)",
                        detail: "\(agentName) works in its own copy of the repo on a new branch, so it won't touch your checkout or other agents.")

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("What should \(agentName) work on?")
                        .font(.ui(size: 12, weight: .medium))
                    Spacer()
                    if Agents.offered.count > 1 {
                        Picker("Agent", selection: $agent) {
                            ForEach(Agents.offered, id: \.id) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .fixedSize()
                    }
                    issueControl
                }
                .animation(Theme.Motion.state, value: issues.isEmpty)
                .animation(Theme.Motion.state, value: issue)
                TextEditor(text: $prompt)
                    .font(.ui(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 96)
                    .background(TerminalTheme.shared.sheetField, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
                    .focused($promptFocused)
                    .tabMovesFocus()
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Branch")
                        .gridColumnAlignment(.trailing)
                    TextField("feat/my-change", text: Binding(
                        get: { branch },
                        set: { branch = $0; branchEdited = true }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.ui(size: 13, design: .monospaced))
                }
                GridRow {
                    Text("From")
                    Picker("From", selection: $base) {
                        ForEach(branches, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .disabled(branches.isEmpty)
                }
            }
            .font(.ui(size: 12))

            DisclosureGroup(isExpanded: $showsSetup) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow {
                        Text("Copy files")
                            .gridColumnAlignment(.trailing)
                        TextField(".env, .env.local", text: $setupFiles)
                            .textFieldStyle(.roundedBorder)
                            .font(.ui(size: 12, design: .monospaced))
                    }
                    GridRow {
                        Text("Then run")
                        TextField(PackageManager.detect(in: parent.url)?.installCommand ?? "npm install", text: $setupCommand)
                            .textFieldStyle(.roundedBorder)
                            .font(.ui(size: 12, design: .monospaced))
                    }
                    GridRow {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        Text("Files are copied from \(parent.name) since git doesn't track them. The command runs in a shell tab. Both are remembered for this project.")
                            .font(.ui(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.ui(size: 12))
                .padding(.top, 8)
            } label: {
                HStack(spacing: 6) {
                    Text("Setup")
                        .font(.ui(size: 12, weight: .medium))
                    if !showsSetup, !setupSummary.isEmpty {
                        Text(setupSummary)
                            .font(.ui(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.snappy(duration: 0.2)) { showsSetup.toggle() } }
            }

            Text(Worktrees.folder(forRepo: parent.url, branch: branch.isEmpty ? "branch" : branch).path.abbreviatingWithTilde)
                .font(.ui(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            if let error {
                Text(error)
                    .font(.ui(size: 12))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                // The button you pressed says what it's doing: its label
                // rolls over to the work in progress, and it grows to fit.
                Button(action: create) {
                    if isCreating {
                        HStack(spacing: 6) {
                            LayerMotion(kind: .arc(NSColor(Theme.onAccent), lineWidth: 1.6))
                                .frame(width: 10, height: 10)
                            Text("Creating worktree…")
                        }
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 5)),
                                                removal: .opacity.combined(with: .offset(y: -5))))
                    } else {
                        Text("Start Agent")
                            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 5)),
                                                    removal: .opacity.combined(with: .offset(y: -5))))
                    }
                }
                .buttonStyle(.prominent)
                .keyboardShortcut(.return, modifiers: .command)
                // Not dimmed while it works, so the label stays readable.
                .allowsHitTesting(!isCreating)
                .disabled(!isCreating && branch.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .animation(Theme.Motion.state, value: isCreating)
        }
        .padding(20)
        .frame(width: 480)
        .terminalSheet()
        .onChange(of: prompt) { _, text in
            // An issue names the branch itself, whatever is typed after.
            if !branchEdited, issue == nil { branch = text.isEmpty ? "" : Worktrees.suggestBranch(from: text) }
        }
        .task {
            issues = GitHubIssues.cached(repo: parent.url)
            issues = await GitHubIssues.load(repo: parent.url)
        }
        .task {
            promptFocused = true
            setupFiles = (parent.setupFiles ?? Worktrees.suggestedSetupFiles(repo: parent.url)).joined(separator: ", ")
            setupCommand = parent.setupCommand ?? ""
            let git = GitClient(root: parent.url)
            branches = await git.branches()
            base = await AgentLauncher.preferredBase(repo: parent.url) ?? ""
            if !base.isEmpty, !branches.contains(base) { branches.insert(base, at: 0) }
        }
    }

    /// Beside the prompt's label: a way to start from one of the repo's
    /// open issues, or the issue that was picked. It sits on the label's
    /// line so the sheet doesn't jump when the issues arrive.
    @ViewBuilder
    private var issueControl: some View {
        if let issue {
            HStack(spacing: 4) {
                Button { showsIssues = true } label: {
                    Label {
                        // Verbatim, or the number gets a thousands separator.
                        Text(verbatim: "Issue #\(issue.number)")
                    } icon: {
                        Image(systemName: "smallcircle.filled.circle")
                    }
                }
                .help(issue.title)
                Button(action: clearIssue) {
                    Image(systemName: "xmark")
                        .font(.ui(size: 9, weight: .semibold))
                        .padding(3)
                        .contentShape(Rectangle())
                }
                .foregroundStyle(.secondary)
                .help("Don't start from this issue")
                .accessibilityLabel("Remove Issue")
            }
            .buttonStyle(.plain)
            .font(.ui(size: 12, weight: .medium))
            .foregroundStyle(Theme.accent)
            .popover(isPresented: $showsIssues, arrowEdge: .bottom) { issuePicker }
            .transition(.opacity)
        } else if !issues.isEmpty {
            Button { showsIssues = true } label: {
                Label("From Issue", systemImage: "smallcircle.filled.circle")
            }
            .buttonStyle(.plain)
            .font(.ui(size: 12))
            .foregroundStyle(.secondary)
            .help("Start from one of this repo's open GitHub issues")
            .popover(isPresented: $showsIssues, arrowEdge: .bottom) { issuePicker }
            .transition(.opacity)
        }
    }

    private var issuePicker: some View {
        IssuePicker(issues: issues, selected: issue, pick: pick)
    }

    /// Whatever was typed besides the picked issue's own prompt.
    private var ownWords: String {
        var text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if let issue, text.hasPrefix(issue.prompt) { text = String(text.dropFirst(issue.prompt.count)) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Starts from an issue: it writes the prompt, above anything already
    /// typed, and names the branch unless you named one.
    private func pick(_ picked: GitHubIssue) {
        let own = ownWords
        issue = picked
        prompt = own.isEmpty ? picked.prompt : picked.prompt + "\n\n" + own
        if !branchEdited { branch = picked.branch }
        showsIssues = false
        promptFocused = true
    }

    private func clearIssue() {
        let own = ownWords
        issue = nil
        prompt = own
        if !branchEdited { branch = own.isEmpty ? "" : Worktrees.suggestBranch(from: own) }
    }

    private var fileList: [String] {
        setupFiles.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// "Copies .env, runs npm install", shown while Setup is collapsed.
    private var setupSummary: String {
        var parts: [String] = []
        if !fileList.isEmpty { parts.append("copies " + fileList.joined(separator: ", ")) }
        let command = setupCommand.trimmingCharacters(in: .whitespaces)
        if !command.isEmpty { parts.append("runs " + command) }
        guard let first = parts.first else { return "" }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + parts.dropFirst()).joined(separator: ", ")
    }

    private func create() {
        let branch = branch.trimmingCharacters(in: .whitespaces)
        let files = fileList
        let command = setupCommand.trimmingCharacters(in: .whitespaces)
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = base.isEmpty ? nil : base
        let fromIssue = issue != nil
        // Command-Return still reaches the button while it works.
        guard !isCreating else { return }
        isCreating = true
        error = nil
        Task {
            do {
                try await AgentLauncher.start(parent: parent, branch: branch, base: base, prompt: prompt, files: files,
                                              command: command, store: store, terminals: terminals, agent: agent)
                Analytics.capture(.agentStarted, ["kind": "single", "count": 1, "from_phone": false, "from_issue": fromIssue])
                dismiss()
            } catch {
                self.error = error.localizedDescription
                isCreating = false
            }
        }
    }
}

extension String {
    /// "/Users/matt/Apps" as "~/Apps".
    var abbreviatingWithTilde: String { (self as NSString).abbreviatingWithTildeInPath }
}
