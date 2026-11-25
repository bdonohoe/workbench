import BenchKit
import SwiftUI

/// The Mac's right sidebar on a wide iPad: the project's Changes, Files
/// and Artifacts beside the conversation. Folders open inside the pane;
/// diffs, files and commits open in the middle, where there's room.
struct InspectorPane: View {
    @Environment(CompanionClient.self) private var client
    @Environment(Navigator.self) private var navigator
    let projectID: UUID
    @AppStorage("inspectorTab") private var tab = InspectorTab.changes
    /// The folder open in Files. The pane has no navigation stack: a
    /// second one in the split view's detail column broke its pushes.
    @State private var folder = ""

    private var project: CompanionProject? { client.snapshot?.projects.first { $0.id == projectID } }

    /// The tabs this project and Mac can fill. A folder without git has no
    /// changes, as on the Mac.
    private var tabs: [InspectorTab] {
        var tabs: [InspectorTab] = []
        if project?.isGit != false { tabs.append(.changes) }
        if client.canBrowseFiles { tabs.append(.files) }
        if client.canListArtifacts { tabs.append(.artifacts) }
        return tabs
    }

    private var shown: InspectorTab { tabs.contains(tab) ? tab : (tabs.first ?? .changes) }

    var body: some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    if tabs.count > 1 { header }
                    // The pane has no navigation bar for these to live in.
                    if shown == .changes, ChangesControls.isAvailable(client, projectID: projectID) {
                        HStack(spacing: 8) { ChangesControls(projectID: projectID, showsBase: true) }
                            .padding(.horizontal, 12)
                            .padding(.bottom, 8)
                    }
                    if shown == .files, !folder.isEmpty { folderBar }
                }
                .background(PhoneTheme.canvas)
            }
            .environment(\.showInMain) { navigator.show($0) }
            // A different tab starts at its top, not in a folder of the last one.
            .onChange(of: tab) { folder = "" }
    }

    /// The tabs.
    private var header: some View {
        Picker("Show", selection: $tab) {
            ForEach(tabs) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// The open folder, with the way back up.
    private var folderBar: some View {
        Button {
            folder = folder.split(separator: "/").dropLast().joined(separator: "/")
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left").font(.footnote.weight(.semibold))
                Text(folder.split(separator: "/").last.map(String.init) ?? folder)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
            }
            .foregroundStyle(PhoneTheme.ink)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back to \(folder.split(separator: "/").dropLast().last.map(String.init) ?? "Project")")
    }

    @ViewBuilder
    private var content: some View {
        switch shown {
        case .changes: ChangesView(projectID: projectID)
        case .files: FilesView(projectID: projectID, folder: folder) { folder = $0 }
        case .artifacts: InspectorArtifacts(projectID: projectID)
        }
    }
}

enum InspectorTab: String, CaseIterable, Identifiable {
    case changes, files, artifacts
    var id: String { rawValue }
    var title: String {
        switch self {
        case .changes: "Changes"
        case .files: "Files"
        case .artifacts: "Artifacts"
        }
    }
}

/// The Artifacts list in the pane, kept current as Claude publishes.
private struct InspectorArtifacts: View {
    @Environment(CompanionClient.self) private var client
    let projectID: UUID

    var body: some View {
        ArtifactsList(links: client.artifacts[projectID])
            .navigationTitle("Artifacts")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: client.status) {
                while !Task.isCancelled, client.status == .connected {
                    client.loadArtifacts(projectID: projectID)
                    try? await Task.sleep(for: .seconds(10))
                }
            }
    }
}

/// A row that opens a diff, file or commit: pushed on a phone, or in the
/// middle pane from the iPad's inspector, where the one showing is marked.
struct OpenLink<Label: View>: View {
    @Environment(\.showInMain) private var showInMain
    @Environment(Navigator.self) private var navigator
    let item: InspectorItem
    @ViewBuilder var label: () -> Label

    var body: some View {
        if let showInMain {
            Button { showInMain(item) } label: {
                HStack {
                    label()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(PhoneTheme.inkMuted.opacity(0.7))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(navigator.shownInspectorItem == item ? PhoneTheme.accent.opacity(0.16) : nil)
        } else {
            switch item {
            case .diff(let route): NavigationLink(value: route, label: label)
            case .file(let route): NavigationLink(value: route, label: label)
            case .commit(let route): NavigationLink(value: route, label: label)
            }
        }
    }
}
