import BenchKit
import SwiftUI

/// The top of the right sidebar while Claude keeps a checklist: how many
/// steps are done, and the list itself. The header folds it away.
struct ChecklistSection: View {
    let items: [ChecklistItem]
    @AppStorage("checklistCollapsed") private var collapsed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureHeader(title: "Checklist", countText: "\(items.doneCount) of \(items.count)", isCollapsed: collapsed) {
                withAnimation(Theme.Motion.state) { collapsed.toggle() }
            }
            .help(collapsed ? "Show the checklist" : "Hide the checklist")
            ChecklistProgressBar(progress: items.progress)
            if !collapsed {
                ChecklistRows(items: items, textSize: 12, spacing: 6, wraps: false)
                    .padding(.top, 2)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }
}

/// Claude's subagents in the right sidebar, under the checklist, while any
/// are running or finished during the turn under way. The header folds it.
struct AgentsSection: View {
    let agents: [AgentStatus]
    @AppStorage("agentsCollapsed") private var collapsed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let running = agents.runningCount
            DisclosureHeader(title: "Agents", countText: running > 0 ? "\(running) working" : "Done", isCollapsed: collapsed) {
                withAnimation(Theme.Motion.state) { collapsed.toggle() }
            }
            .help(collapsed ? "Show the agents" : "Hide the agents")
            if !collapsed {
                AgentStatusRows(agents: agents)
                    .padding(.top, 2)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }
}

/// The right sidebar for a project on this Mac: its checklist, when Claude
/// keeps one, above its changes or its files.
struct LocalInspector: View {
    @Environment(TerminalManager.self) private var terminals
    @Environment(RepoMonitors.self) private var monitors
    @AppStorage("inspectorMode") private var mode = InspectorMode.changes
    let project: Project

    private var library: ArtifactLibrary { .shared }

    private var isRepository: Bool { monitors.monitor(for: project).snapshot?.isRepository ?? true }

    var body: some View {
        VStack(spacing: 0) {
            InspectorBand {
                InspectorModePicker(mode: $mode, artifactCount: library.links(for: project).count, hasChanges: isRepository)
            }
            Divider()
            if let items = terminals.checklist(for: project) {
                ChecklistSection(items: items)
                Divider()
            }
            if let agents = terminals.agents(for: project) {
                AgentsSection(agents: agents)
                Divider()
            }
            if !isRepository {
                NotRepositoryBar()
            }
            switch mode {
            case .artifacts:
                ArtifactsPanel(links: library.links[project.path])
            case .changes where isRepository:
                ChangesPanel(project: project)
            default:
                FilesPanel(project: project)
            }
        }
        // New pages turn up as Claude publishes them.
        .task(id: project.path) {
            while !Task.isCancelled {
                library.refresh(path: project.path)
                try? await Task.sleep(for: .seconds(5))
            }
        }
        // The changes panel usually does this, but a folder without git
        // still needs watching to notice a `git init`.
        .onAppear { monitors.focus(on: project.id) }
        .onChange(of: project.id) { _, id in monitors.focus(on: id) }
        .animation(.snappy(duration: 0.2), value: terminals.checklist(for: project) == nil)
        .animation(.snappy(duration: 0.2), value: terminals.agents(for: project) == nil)
        .ignoresSafeArea(.container, edges: .top)
        // The checklist's colors follow the theme, like the chat's.
        .environment(\.companionPalette, TerminalTheme.shared.chatPalette)
        .terminalPanelBackground()
    }
}

/// The same for a project on another Mac. The checklist follows the
/// session tab that's open, else the project's busiest session.
struct RemoteInspector: View {
    @Environment(RemoteMacs.self) private var macs
    @AppStorage("inspectorMode") private var mode = InspectorMode.changes
    let host: String
    let projectID: UUID

    private var items: [ChecklistItem]? {
        guard let project = macs.client(for: host)?.snapshot?.projects.first(where: { $0.id == projectID }) else { return nil }
        if case .session(let id) = macs.openTabs[RemoteMacs.key(host: host, projectID: projectID)],
           let list = project.sessions.first(where: { $0.id == id })?.checklist, !list.isEmpty {
            return list
        }
        return project.checklist
    }

    private var agents: [AgentStatus]? {
        guard let project = macs.client(for: host)?.snapshot?.projects.first(where: { $0.id == projectID }) else { return nil }
        if case .session(let id) = macs.openTabs[RemoteMacs.key(host: host, projectID: projectID)],
           let pinned = project.sessions.first(where: { $0.id == id })?.pinnedAgents {
            return pinned
        }
        let all = project.sessions.compactMap(\.pinnedAgents).flatMap { $0 }
        return all.isEmpty ? nil : all
    }

    private var isRepository: Bool { macs.client(for: host)?.changes[projectID]?.isRepository ?? true }

    var body: some View {
        let client = macs.client(for: host)
        VStack(spacing: 0) {
            InspectorBand {
                if client?.canListArtifacts == true {
                    InspectorModePicker(mode: $mode, artifactCount: client?.artifacts[projectID]?.count ?? 0, hasChanges: isRepository)
                } else if isRepository {
                    InspectorModePicker(mode: Binding(get: { mode == .files ? .files : .changes }, set: { mode = $0 }),
                                        artifactCount: 0)
                }
            }
            Divider()
            if let items {
                ChecklistSection(items: items)
                Divider()
            }
            if let agents {
                AgentsSection(agents: agents)
                Divider()
            }
            switch mode {
            case .artifacts where client?.canListArtifacts == true:
                ArtifactsPanel(links: client?.artifacts[projectID], opensInTabs: false)
            case .files where isRepository:
                RemoteFilesPanel(host: host, projectID: projectID)
            default:
                // Shows the files itself for a folder without git, and
                // keeps watching to notice a `git init`.
                RemoteChangesPanel(host: host, projectID: projectID)
            }
        }
        .task(id: "\(projectID)-\(macs.client(for: host)?.status == .connected)") {
            while !Task.isCancelled {
                macs.client(for: host)?.loadArtifacts(projectID: projectID)
                try? await Task.sleep(for: .seconds(10))
            }
        }
        .animation(.snappy(duration: 0.2), value: items == nil)
        .animation(.snappy(duration: 0.2), value: agents == nil)
        .ignoresSafeArea(.container, edges: .top)
        .environment(\.companionPalette, TerminalTheme.shared.chatPalette)
        .terminalPanelBackground()
    }
}
