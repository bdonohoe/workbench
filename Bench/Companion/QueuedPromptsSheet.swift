import AppKit
import SwiftUI

/// Prompts queued from the phone that couldn't start. Each can be copied,
/// started in another git project, or deleted.
struct QueuedPromptsSheet: View {
    @Environment(OfflineQueue.self) private var queue
    @Environment(\.dismiss) private var dismiss
    /// Retries started here that haven't finished. The sheet stays open
    /// while any run, so a failure shows up in the list.
    @State private var retrying: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Queued Prompts That Couldn't Start")
                .font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(queue.failed) { item in
                        QueuedPromptRow(item: item) { target in
                            retrying.insert(item.id)
                            Task {
                                await queue.retry(item.id, in: target)
                                retrying.remove(item.id)
                            }
                        }
                        if item.id != queue.failed.last?.id { Divider() }
                    }
                }
            }
            .frame(maxHeight: 420)
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { closeIfDone() }
        .onChange(of: queue.failed.isEmpty) { closeIfDone() }
        .onChange(of: retrying) { closeIfDone() }
    }

    private func closeIfDone() {
        if queue.failed.isEmpty, retrying.isEmpty { dismiss() }
    }
}

private struct QueuedPromptRow: View {
    let item: OfflineQueue.FailedPrompt
    let start: (UUID) -> Void
    @Environment(AppStore.self) private var store
    @Environment(OfflineQueue.self) private var queue
    @State private var target: UUID?
    @State private var confirmsDelete = false

    /// A prompt that couldn't be unlocked has no text to copy or start.
    private var hasText: Bool { !item.prompt.prompt.isEmpty }

    private var gitProjects: [Project] {
        store.topLevelProjects.filter { OfflineQueue.isGitFolder($0.url) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if hasText {
                Text(item.prompt.projectName).font(.subheadline.weight(.semibold))
                Text(item.prompt.prompt)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(item.reason)
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                if hasText {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.prompt.prompt, forType: .string)
                    }
                    if gitProjects.isEmpty {
                        Text("No git projects to start it in.").foregroundStyle(.secondary)
                    } else {
                        Picker("Start in…", selection: $target) {
                            ForEach(gitProjects) { Text($0.name).tag(Optional($0.id)) }
                        }
                        .fixedSize()
                        Button("Start") {
                            if let target { start(target) }
                        }
                        .disabled(target == nil)
                    }
                }
                Spacer()
                Button("Delete", role: .destructive) { confirmsDelete = true }
                    .confirmationDialog("Delete this queued prompt?", isPresented: $confirmsDelete) {
                        Button("Delete", role: .destructive) { queue.discard(item.id) }
                    } message: {
                        Text("You can't get it back.")
                    }
            }
            .controlSize(.small)
        }
        .onAppear {
            if target == nil {
                let original = store.rootID(of: item.prompt.projectID)
                target = gitProjects.contains { $0.id == original } ? original : gitProjects.first?.id
            }
        }
    }
}
