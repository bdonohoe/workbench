import BenchKit
import SwiftUI

/// A remote project's past conversations, newest first. Pick one to open
/// it in a Claude tab on that Mac.
struct RemotePastSessionsPopover: View {
    @Environment(RemoteMacs.self) private var macs
    let host: String
    let projectID: UUID
    let dismiss: () -> Void
    @State private var search = ""

    private var client: CompanionClient? { macs.client(for: host) }
    private var sessions: [PastSessionSummary]? { client?.pastSessions[projectID] }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Titles and prompts", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(10)
            Divider()
            if let sessions {
                if sessions.isEmpty {
                    ContentUnavailableView("No Past Sessions", systemImage: "clock.arrow.circlepath",
                                           description: Text("Conversations in this project show up here once there are some."))
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(filtered(sessions)) { session in
                                Button {
                                    client?.resume(projectID: projectID, sessionID: session.id)
                                    dismiss()
                                } label: {
                                    HStack(alignment: .top) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(session.title ?? session.firstPrompt ?? "Untitled")
                                                .font(.ui(size: 12, weight: .semibold)).lineLimit(1)
                                            if session.title != nil, let prompt = session.firstPrompt {
                                                Text(prompt).font(.ui(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                                            }
                                            HStack(spacing: 8) {
                                                Text(session.modified, format: .relative(presentation: .named))
                                                if let branch = session.branch {
                                                    Label(branch, systemImage: "arrow.triangle.branch").lineLimit(1)
                                                }
                                            }
                                            .font(.ui(size: 10))
                                            .foregroundStyle(.tertiary)
                                        }
                                        Spacer()
                                        Text(session.openTabID == nil ? "Resume" : "Open")
                                            .font(.ui(size: 11, weight: .medium))
                                            .foregroundStyle(session.openTabID == nil ? Theme.accent : .secondary)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.pressable)
                                Divider().padding(.leading, 12)
                            }
                        }
                    }
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 380, height: 360)
        .task(id: client?.status) {
            if client?.status == .connected { client?.loadPastSessions(projectID: projectID) }
        }
    }

    private func filtered(_ sessions: [PastSessionSummary]) -> [PastSessionSummary] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return sessions }
        return sessions.filter { session in
            [session.title, session.firstPrompt, session.lastPrompt, session.branch]
                .contains { $0?.localizedCaseInsensitiveContains(query) == true }
        }
    }
}

/// Start an agent on its own branch on the other Mac. Bench there makes
/// the worktree with the project's saved setup and starts Claude with
/// the prompt.
struct RemoteNewAgentSheet: View {
    @Environment(RemoteMacs.self) private var macs
    @Environment(\.dismiss) private var dismiss
    let host: String
    let projectID: UUID
    @State private var prompt = ""
    @State private var branch = ""
    /// Nil starts from the branch that Mac would pick, usually main.
    @State private var base: String?
    @State private var isStarting = false
    /// Whether this sheet asked for the project's changes (for its branch
    /// list), so it stops them again when it closes.
    @State private var startedWatching = false
    @FocusState private var promptFocused: Bool

    private var client: CompanionClient? { macs.client(for: host) }
    private var project: CompanionProject? { client?.snapshot?.projects.first { $0.id == projectID } }
    private var bases: [String]? { client?.agentBases(projectID: projectID) }
    private var trimmedBranch: String { branch.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New Agent in \(project?.name ?? "the project") on \(macs.name(for: host))")
                    .font(.ui(size: 15, weight: .semibold))
                Text("The agent works in its own copy of the repo on a new branch there. The setup files and command saved for the project on that Mac are used, or its .env files if none are saved.")
                    .font(.ui(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("What should the agent work on?")
                    .font(.ui(size: 12, weight: .medium))
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
                    Text("Branch").gridColumnAlignment(.trailing)
                    TextField("Suggested from the task", text: $branch)
                        .textFieldStyle(.roundedBorder)
                        .font(.ui(size: 13, design: .monospaced))
                }
                GridRow {
                    Text("Start from")
                    Picker("Start from", selection: $base) {
                        Text("Default branch").tag(String?.none)
                        if let bases, !bases.isEmpty {
                            Divider()
                            ForEach(bases, id: \.self) { Text($0).tag(String?.some($0)) }
                        }
                    }
                    .labelsHidden()
                    .disabled(bases == nil)
                    .help(bases == nil ? "Loading that Mac's branches…" : "The branch the new one starts from")
                }
            }
            if !trimmedBranch.isEmpty, bases?.contains(trimmedBranch) == true {
                Text("\(trimmedBranch) already exists there, so the agent picks it up where it left off instead of starting fresh.")
                    .font(.ui(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem = client?.lastProblem {
                Text(problem).font(.ui(size: 12)).foregroundStyle(Theme.Status.failed)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isStarting ? "Starting…" : "Start Agent") {
                    isStarting = true
                    client?.newAgent(parentID: projectID, prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                                     branch: trimmedBranch, base: base)
                }
                .buttonStyle(.prominent)
                .keyboardShortcut(.defaultAction)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isStarting)
            }
        }
        .padding(20)
        .frame(width: 480)
        .terminalSheet()
        .onAppear {
            client?.clearLastProblem()
            promptFocused = true
            if let client, !client.isWatchingChanges(projectID) {
                startedWatching = true
                client.watchChanges(projectID: projectID)
            }
        }
        .onDisappear { if startedWatching { client?.unwatchChanges(projectID: projectID) } }
        .onChange(of: client?.lastProblem) { _, problem in if problem != nil { isStarting = false } }
        // A dropped connection never answers, so don't wait on it.
        .onChange(of: client?.status) { _, status in if status != .connected { isStarting = false } }
        .onChange(of: client?.started?.sessionID) { _, id in if id != nil { dismiss() } }
    }
}
