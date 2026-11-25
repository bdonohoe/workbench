import BenchKit
import SwiftUI

/// A project's past Claude sessions. Clicking one picks it back up in a new
/// Claude tab, or switches to the tab it's already open in.
struct HistoryPopover: View {
    @Environment(AppStore.self) private var store
    let project: Project
    let dismiss: () -> Void

    @State private var sessions: [PastSession]?
    @State private var openTabs: [String: UUID] = [:]
    @State private var search = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Past Sessions")
                    .font(.ui(size: 13, weight: .semibold))
                TextField("Search titles and prompts", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .font(.ui(size: 12))
                    .focused($searchFocused)
                    .onSubmit { if let first = filtered.first { open(first) } }
            }
            .padding(12)
            Divider()
            content
        }
        .frame(width: 440)
        .task {
            searchFocused = true
            openTabs = AgentSessions.openSessions()
            sessions = await SessionHistory.load(projectPath: project.path)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let sessions {
            if sessions.isEmpty {
                Text("No past sessions in \(project.name) yet.")
                    .font(.ui(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(24)
            } else if filtered.isEmpty {
                Text("Nothing matches “\(search)”.")
                    .font(.ui(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filtered) { session in
                            HistoryRow(session: session, isOpen: isOpenHere(session)) { open(session) }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 440)
                .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(24)
        }
    }

    private var filtered: [PastSession] {
        let sessions = sessions ?? []
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return sessions }
        return sessions.filter { session in
            [session.title, session.firstPrompt, session.lastPrompt, session.branch]
                .contains { $0?.localizedCaseInsensitiveContains(query) == true }
        }
    }

    /// Open in one of this project's tabs right now.
    private func isOpenHere(_ session: PastSession) -> Bool {
        guard let tab = openTabs[session.id] else { return false }
        return project.tabs.contains { $0.id == tab }
    }

    private func open(_ session: PastSession) {
        if let tab = openTabs[session.id], project.tabs.contains(where: { $0.id == tab }) {
            store.selectTab(tab, in: project.id)
        } else {
            store.addTab(.agent, to: project.id, resuming: session.id, title: session.title.map(Self.tabTitle), agent: session.agent)
        }
        dismiss()
    }

    /// Keeps a resumed tab's title short.
    private static func tabTitle(_ title: String) -> String {
        title.count > 24 ? String(title.prefix(23)) + "…" : title
    }
}

private struct HistoryRow: View {
    let session: PastSession
    let isOpen: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.title ?? session.firstPrompt ?? "Untitled")
                        .font(.ui(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if let prompt = detail {
                        Text(prompt)
                            .font(.ui(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    HStack(spacing: 8) {
                        Text(session.modified, format: .relative(presentation: .named))
                        if let branch = session.branch {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.triangle.branch")
                                    .font(.ui(size: 9))
                                Text(branch)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    .font(.ui(size: 11))
                    .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 6)
                Text(isOpen ? "Open" : "Resume")
                    .font(.ui(size: 11, weight: .medium))
                    .foregroundStyle(isOpen ? Color.secondary : Theme.accent)
                    .opacity(isHovering || isOpen ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.07 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .onHover { isHovering = $0 }
        .help(isOpen ? "Switch to the tab it's open in" : "Pick this conversation back up in a new \(Agents.provider(session.agent)?.name ?? Agents.standard.name) tab")
    }

    /// Your first prompt under Claude's title, or the latest one when the
    /// first is already the title.
    private var detail: String? {
        if session.title != nil { return session.firstPrompt }
        return session.lastPrompt == session.firstPrompt ? nil : session.lastPrompt.map { "Latest: \($0)" }
    }
}
