import BenchKit
import SwiftUI

struct FilesRoute: Hashable {
    var projectID: UUID
    /// The folder to list, relative to the project. "" is the project itself.
    var folder = ""
}

struct FileRoute: Hashable {
    var projectID: UUID
    var path: String
}

/// A project's files on the Mac, one folder at a time.
struct FilesView: View {
    @Environment(CompanionClient.self) private var client
    let projectID: UUID
    let folder: String
    /// Opens a folder in place, for the iPad's inspector.
    var openFolder: ((String) -> Void)?

    private var project: CompanionProject? { client.snapshot?.projects.first { $0.id == projectID } }
    private var tree: FileTree? { client.fileTrees[projectID] }

    var body: some View {
        Group {
            if !client.canBrowseFiles {
                ContentUnavailableView("Update Workbench on your Mac", systemImage: "folder",
                                       description: Text("This Mac's version of Workbench can't share its files yet."))
            } else if let tree {
                let entries = tree.children[folder] ?? []
                if entries.isEmpty {
                    ContentUnavailableView("No files", systemImage: "folder")
                } else {
                    List {
                        Group {
                            if folder.isEmpty, client.truncatedFiles.contains(projectID) {
                                Text("This project has more files than Workbench lists. Some are left out.")
                                    .font(.footnote)
                                    .foregroundStyle(PhoneTheme.inkMuted)
                            }
                            ForEach(entries, id: \.path) { entry in
                                if entry.isDirectory, let openFolder {
                                    // In the iPad's inspector, which has no stack of its own.
                                    Button { openFolder(entry.path) } label: {
                                        HStack {
                                            Label(entry.name, systemImage: "folder")
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .font(.footnote.weight(.semibold))
                                                .foregroundStyle(PhoneTheme.inkMuted.opacity(0.7))
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                } else if entry.isDirectory {
                                    NavigationLink(value: FilesRoute(projectID: projectID, folder: entry.path)) {
                                        Label(entry.name, systemImage: "folder")
                                    }
                                } else {
                                    OpenLink(item: .file(FileRoute(projectID: projectID, path: entry.path))) {
                                        Label(entry.name, systemImage: FileIcon.symbol(for: entry.name))
                                    }
                                }
                            }
                        }
                        .listRowBackground(PhoneTheme.surface)
                        .foregroundStyle(PhoneTheme.ink)
                    }
                    .listStyle(.insetGrouped)
                }
            } else {
                LoadingState()
            }
        }
        .scrollContentBackground(.hidden)
        .background(PhoneTheme.canvas)
        .navigationTitle(folder.isEmpty ? (project?.name ?? "Files") : String(folder.split(separator: "/").last ?? ""))
        .navigationBarTitleDisplayMode(.inline)
        .watchingFiles(of: projectID)
    }
}

/// One file from the Mac, reloading when it changes there.
struct FileScreen: View {
    @Environment(CompanionClient.self) private var client
    let projectID: UUID
    let path: String

    private var content: FileContent? { client.fileContents["\(projectID):\(path)"] }
    /// The text with its colors, made once per change of the file or its
    /// colors. Making it in the body ran on every draw.
    @State private var colored: AttributedString?

    var body: some View {
        Group {
            switch content {
            case .text(let text)?:
                ScrollView([.vertical, .horizontal]) {
                    Text(colored ?? AttributedString(text))
                        // Follows the system text size, like the bars around it.
                        .font(.caption.monospaced())
                        .foregroundStyle(PhoneTheme.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            case .image(let data)?:
                if let image = UIImage(data: data) {
                    ScrollView([.vertical, .horizontal]) {
                        Image(uiImage: image).resizable().scaledToFit().padding(12)
                    }
                } else {
                    ContentUnavailableView("Can't show this image", systemImage: "photo")
                }
            case .binary(let size)?:
                ContentUnavailableView("Not a text file", systemImage: "doc",
                                       description: Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))
            case .tooLarge(let size)?:
                ContentUnavailableView("Too large to show", systemImage: "doc",
                                       description: Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))
            case .missing?:
                ContentUnavailableView("File not found", systemImage: "questionmark.folder",
                                       description: Text("It may have been moved or deleted on your Mac."))
            case nil:
                LoadingState()
            }
        }
        .background(PhoneTheme.canvas)
        .navigationTitle(String(path.split(separator: "/").last ?? Substring(path)))
        .navigationBarTitleDisplayMode(.inline)
        .watchingFiles(of: projectID)
        .task(id: Revision(connected: client.status == .connected, revision: client.fileRevisions[projectID])) {
            guard client.status == .connected else { return }
            client.requestFile(projectID: projectID, path: path)
        }
        .onChange(of: Coloring(content: content, runs: client.fileCode["\(projectID):\(path)"]), initial: true) { _, now in
            colored = now.text.map { color($0, runs: now.runs) }
        }
    }

    /// The text with its code colored, once the Mac has sent the colors.
    /// Very long files stay plain, since one huge styled text is slow.
    private func color(_ text: String, runs: [CodeRun]?) -> AttributedString {
        guard let runs, text.utf16.count <= 300_000 else { return AttributedString(text) }
        return codeText(text, runs: runs)
    }

    /// What the colored text is made from.
    private struct Coloring: Equatable {
        var content: FileContent?
        var runs: [CodeRun]?
        var text: String? { if case .text(let text)? = content { text } else { nil } }
    }

    private struct Revision: Equatable {
        var connected: Bool
        var revision: Int?
    }
}

private extension View {
    /// Keeps the Mac sending this project's file list while the view shows.
    func watchingFiles(of projectID: UUID) -> some View {
        modifier(WatchingFiles(projectID: projectID))
    }
}

private struct WatchingFiles: ViewModifier {
    @Environment(CompanionClient.self) private var client
    let projectID: UUID

    func body(content: Content) -> some View {
        content.task {
            client.watchFiles(projectID: projectID)
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
            client.unwatchFiles(projectID: projectID)
        }
    }
}
