import BenchKit
import SwiftUI

/// The Files sidebar for a project on another Mac.
struct RemoteFilesPanel: View {
    @Environment(RemoteMacs.self) private var macs
    let host: String
    let projectID: UUID

    private var client: CompanionClient? { macs.client(for: host) }
    private var key: String { RemoteMacs.key(host: host, projectID: projectID) }

    private var selectedPath: String? {
        if case .file(let path) = macs.openTabs[key] { return path }
        return nil
    }

    var body: some View {
        Group {
            if let client, client.status == .connected, !client.canBrowseFiles {
                ContentUnavailableView("Update Workbench There", systemImage: "arrow.triangle.2.circlepath",
                                       description: Text("Workbench on \(macs.name(for: host)) is too old to share its files. Update it and relaunch it."))
            } else {
                FileTreeList(
                    tree: client?.fileTrees[projectID],
                    expanded: Binding(
                        get: { macs.expandedFolders[key] ?? [] },
                        set: { macs.expandedFolders[key] = $0 }
                    ),
                    truncated: client?.truncatedFiles.contains(projectID) ?? false,
                    kinds: kinds,
                    selectedPath: selectedPath,
                    root: client?.snapshot?.projects.first { $0.id == projectID }?.path,
                    open: { macs.openFile(host: host, projectID: projectID, path: $0) }
                )
                .id(key)
            }
        }
        // The client asks again by itself after reconnecting.
        .task(id: key) {
            guard let client else { return }
            client.watchFiles(projectID: projectID)
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
            client.unwatchFiles(projectID: projectID)
        }
    }

    /// Changed files, when the changes list has been loaded.
    private var kinds: [String: ChangeKind] {
        guard let changes = client?.changes[projectID] else { return [:] }
        var kinds: [String: ChangeKind] = [:]
        for change in changes.againstBase + changes.staged + changes.unstaged { kinds[change.path] = change.kind }
        return kinds
    }
}

/// One file from the other Mac, reloading as it changes there.
struct RemoteFileView: View {
    @Environment(RemoteMacs.self) private var macs
    let host: String
    let projectID: UUID
    let path: String

    private var client: CompanionClient? { macs.client(for: host) }

    var body: some View {
        let content = client?.fileContents["\(projectID):\(path)"]
        VStack(spacing: 0) {
            FileHeader(path: path, content: content) { EmptyView() }
            Divider()
            FileContentView(content: content, path: path)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task {
            guard let client else { return }
            client.watchFiles(projectID: projectID)
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
            client.unwatchFiles(projectID: projectID)
        }
        .task(id: Revision(connected: client?.status == .connected, revision: client?.fileRevisions[projectID])) {
            guard client?.status == .connected else { return }
            client?.requestFile(projectID: projectID, path: path)
        }
    }

    private struct Revision: Equatable {
        var connected: Bool
        var revision: Int?
    }
}
