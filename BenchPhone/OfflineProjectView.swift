import BenchKit
import SwiftUI

/// A project while its Mac is out of reach: a box to queue a prompt for
/// when the Mac is back, and what's already queued underneath.
struct OfflineProjectView: View {
    @Environment(CompanionClient.self) private var client
    @Environment(QueueStore.self) private var queue
    let projectID: UUID

    @State private var draft = ""
    @State private var isSending = false
    @State private var problem: String?
    /// The queued prompt being changed in place, and its new text.
    @State private var editingID: UUID?
    @State private var editText = ""
    @FocusState private var composing: Bool
    @FocusState private var editing: Bool

    private var project: CompanionProject? { client.snapshot?.projects.first { $0.id == projectID } }
    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        List {
            OfflineNote()
                .padding(.bottom, 4)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            // An old pairing code: the Mac reads another mailbox now, so
            // nothing queued here would reach it.
            if !client.needsRepair {
                Section {
                    box
                } footer: {
                    if let problem {
                        Text(problem).foregroundStyle(PhoneTheme.error)
                    }
                }
            }
            let queued = queue.items(projectID: projectID)
            if !queued.isEmpty {
                Section("Queued") {
                    ForEach(queued) { item in
                        row(item)
                            .listRowBackground(PhoneTheme.surface)
                            .swipeActions(edge: .trailing) {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    Task { await queue.delete(item.id) }
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(PhoneTheme.canvas)
        .navigationTitle(project?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.snappy(duration: 0.25), value: queue.items(projectID: projectID))
        .task { await queue.refresh() }
    }

    // MARK: The box

    /// The text box, or why there isn't one.
    @ViewBuilder
    private var box: some View {
        if !queue.isAvailable {
            reason("Queuing isn't available in this build.")
        } else if !client.savedFeatures.contains(CompanionFeature.offlineQueue) {
            reason("Update Workbench on your Mac to queue prompts while it's asleep.")
        } else if project?.isGit == false {
            reason("Queued prompts need a git project.")
        } else {
            VStack(alignment: .leading, spacing: 10) {
                TextField("What should the agent do?", text: $draft, axis: .vertical)
                    .lineLimit(4...10)
                    .focused($composing)
                HStack {
                    Text("Starts on a new branch, named from the prompt.")
                        .font(.caption)
                        .foregroundStyle(PhoneTheme.inkMuted)
                    Spacer(minLength: 8)
                    Button {
                        send()
                    } label: {
                        if isSending { ProgressView() } else { Text("Queue") }
                    }
                    .buttonStyle(.phonePrimaryCompact)
                    .disabled(trimmedDraft.isEmpty || isSending || project == nil)
                }
            }
            .padding(.vertical, 4)
            .listRowBackground(PhoneTheme.surface)
        }
    }

    private func reason(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(PhoneTheme.inkMuted)
            .listRowBackground(PhoneTheme.surface)
    }

    private func send() {
        guard let project, !trimmedDraft.isEmpty else { return }
        let text = trimmedDraft
        isSending = true
        problem = nil
        Task {
            problem = await queue.queue(text, project: project)
            // Kept in the box when it couldn't be queued, to change and try again.
            if problem == nil { draft = "" }
            isSending = false
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func row(_ item: LocalQueued) -> some View {
        if editingID == item.id {
            VStack(alignment: .leading, spacing: 8) {
                TextField("What should the agent do?", text: $editText, axis: .vertical)
                    .lineLimit(2...10)
                    .focused($editing)
                HStack {
                    Button("Cancel") { editingID = nil }
                        .buttonStyle(.borderless)
                    Spacer()
                    Button("Save") { save(item) }
                        .buttonStyle(.borderless)
                        .fontWeight(.semibold)
                        .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .font(.subheadline)
            }
            .padding(.vertical, 2)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(status(item))
                    .font(.caption2.weight(.semibold))
                    .textCase(item.status == .expired ? nil : .uppercase)
                    .foregroundStyle(item.status == .expired ? PhoneTheme.inkMuted : PhoneTheme.accent)
                Text(item.prompt.prompt)
                    .font(.subheadline)
                    .foregroundStyle(PhoneTheme.ink)
                    .lineLimit(4)
                if item.status != .expired, let expiry = QueueSync.expiryNote(queuedAt: item.prompt.queuedAt, now: .now) {
                    Text(expiry).font(.caption).foregroundStyle(PhoneTheme.inkMuted)
                }
                if item.status == .expired {
                    HStack(spacing: 18) {
                        Button("Queue Again") { again(item) }
                            .fontWeight(.semibold)
                        Button("Delete", role: .destructive) { Task { await queue.delete(item.id) } }
                    }
                    .buttonStyle(.borderless)
                    .font(.subheadline)
                    .padding(.top, 2)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onTapGesture {
                editText = item.prompt.prompt
                editingID = item.id
                editing = true
            }
            .accessibilityAddTraits(.isButton)
        }
    }

    private func status(_ item: LocalQueued) -> String {
        switch item.status {
        case .waiting: "Waiting for your Mac"
        case .unsent: "Not sent yet"
        case .expired: "Expired: your Mac wasn't online for 14 days"
        }
    }

    private func save(_ item: LocalQueued) {
        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        editingID = nil
        guard text != item.prompt.prompt else { return }
        problem = nil
        Task { problem = await queue.edit(item.id, text: text) }
    }

    private func again(_ item: LocalQueued) {
        problem = nil
        Task { problem = await queue.queueAgain(item.id) }
    }
}
