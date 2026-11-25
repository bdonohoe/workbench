import AppKit
import BenchKit
import SwiftUI

/// Changes or Files, at the top of the right sidebar's lower part.
/// Sits where the Changes and Files switch would, for a folder that
/// isn't a git repository and so has no changes to show.
struct NotRepositoryBar: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.ui(size: 11, weight: .semibold))
            Text("Not a Git repository")
                .font(.ui(size: 12, weight: .medium))
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .help("Workbench shows changes, diffs, and branches for folders tracked with git. Run git init here to start.")
    }
}

/// The Files sidebar for a project on this Mac.
struct FilesPanel: View {
    @Environment(AppStore.self) private var store
    @Environment(FileListMonitors.self) private var files
    @Environment(RepoMonitors.self) private var repos
    let project: Project

    /// What git says about each changed file, to color it in the tree.
    private var kinds: [String: ChangeKind] {
        guard let snapshot = repos.monitor(for: project).snapshot else { return [:] }
        var kinds: [String: ChangeKind] = [:]
        for change in snapshot.againstBase + snapshot.staged + snapshot.unstaged { kinds[change.path] = change.kind }
        return kinds
    }

    var body: some View {
        @Bindable var monitor = files.monitor(for: project)
        FileTreeList(
            tree: monitor.tree,
            expanded: $monitor.expanded,
            truncated: monitor.listing?.truncated ?? false,
            kinds: kinds,
            selectedPath: project.selectedTab?.kind == .file ? project.selectedTab?.filePath : nil,
            root: project.path,
            open: { store.openFile($0, in: project.id) },
            reveal: { path in
                NSWorkspace.shared.activateFileViewerSelecting([project.url.appendingPathComponent(path)])
            }
        )
        .id(project.id)
        .task(id: project.id) {
            // The changes panel normally starts git watching; do it here
            // too so changed files get their colors.
            repos.focus(on: project.id)
            await monitor.hold()
        }
    }
}

/// A project's folders and files, opened and closed like Finder's list
/// view, with a filter field. Shared by projects here and on other Macs.
struct FileTreeList: View {
    let tree: FileTree?
    @Binding var expanded: Set<String>
    let truncated: Bool
    var kinds: [String: ChangeKind] = [:]
    let selectedPath: String?
    /// The project's folder, for copying a file's full path. On another
    /// Mac it's that Mac's folder.
    var root: String?
    let open: (String) -> Void
    /// Shows the file in Finder. Only for files on this Mac.
    var reveal: ((String) -> Void)?

    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            filterField
            Divider()
            if let tree {
                list(tree)
            } else {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var filterField: some View {
        HStack(spacing: 5) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.ui(size: 10))
                .foregroundStyle(.secondary)
            TextField("Filter", text: $query)
                .textFieldStyle(.plain)
                .font(.ui(size: 11))
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                // A 20pt target that takes the mark's own room in the row.
                .padding(-3)
                .help("Clear the filter")
                .accessibilityLabel("Clear the filter")
            } else if !expanded.isEmpty {
                Button {
                    expanded = []
                } label: {
                    Image(systemName: "rectangle.compress.vertical").foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .padding(-3)
                .help("Close all folders")
                .accessibilityLabel("Close all folders")
            }
        }
        .font(.ui(size: 11))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func list(_ tree: FileTree) -> some View {
        let filtering = !query.trimmingCharacters(in: .whitespaces).isEmpty
        let rows = filtering ? tree.rows(matching: query.trimmingCharacters(in: .whitespaces)) : tree.rows(expanded: expanded)
        if rows.isEmpty {
            Text(filtering ? "No matching files" : "No files")
                .font(.ui(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            Spacer(minLength: 0)
        } else {
            let changedFolders = Self.folders(containing: kinds.keys)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        FileTreeRow(
                            row: row,
                            showsPath: filtering,
                            isExpanded: expanded.contains(row.entry.path),
                            isSelected: row.entry.path == selectedPath,
                            kind: kinds[row.entry.path],
                            hasChanges: row.entry.isDirectory && changedFolders.contains(row.entry.path)
                        ) {
                            if row.entry.isDirectory {
                                if expanded.contains(row.entry.path) { expanded.remove(row.entry.path) } else { expanded.insert(row.entry.path) }
                            } else {
                                open(row.entry.path)
                            }
                        }
                        .contextMenu { menu(for: row.entry) }
                    }
                    if truncated {
                        Text("Only the first \(tree.fileCount.formatted()) files are listed.")
                            .font(.ui(size: Theme.TypeScale.meta))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private func menu(for entry: FileTree.Entry) -> some View {
        if !entry.isDirectory {
            Button("Open") { open(entry.path) }
        }
        if let reveal {
            Button("Show in Finder") { reveal(entry.path) }
        }
        Divider()
        CopyPathButtons(path: entry.path, root: root)
    }

    /// Every folder above a changed file, so closed folders can show a dot.
    private static func folders(containing paths: some Sequence<String>) -> Set<String> {
        var folders = Set<String>()
        for path in paths {
            var parts = path.split(separator: "/")
            parts.removeLast()
            while !parts.isEmpty {
                folders.insert(parts.joined(separator: "/"))
                parts.removeLast()
            }
        }
        return folders
    }
}

private struct FileTreeRow: View {
    let row: FileTree.Row
    let showsPath: Bool
    let isExpanded: Bool
    let isSelected: Bool
    let kind: ChangeKind?
    let hasChanges: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if row.entry.isDirectory {
                    Image(systemName: "chevron.right")
                        .font(.ui(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 10)
                } else {
                    Color.clear.frame(width: 10, height: 1)
                }
                Image(systemName: row.entry.isDirectory ? "folder.fill" : FileIcon.symbol(for: row.entry.name))
                    .font(.ui(size: 10))
                    .foregroundStyle(row.entry.isDirectory ? AnyShapeStyle(Theme.accent.opacity(0.75)) : AnyShapeStyle(.secondary))
                    .frame(width: 14)
                Text(row.entry.name)
                    .foregroundStyle(kind?.color ?? .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if showsPath {
                    Text(directory)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 4)
                if hasChanges && !isExpanded {
                    Circle().fill(Theme.Status.modified).frame(width: 5, height: 5)
                        .help("Has changed files")
                }
            }
            // The same text size and row height as a row in the Changes
            // panel, which shares this sidebar.
            .font(.ui(size: Theme.TypeScale.meta))
            .frame(height: 16)
            // 6pt of this used to be row padding; now it's the inset outside the fill.
            .padding(.leading, 2 + CGFloat(row.depth) * 12)
            .padding(.trailing, 6)
            .padding(.vertical, 3)
            .inspectorRow(isSelected: isSelected, isHovering: isHovering)
        }
        .buttonStyle(.pressable)
        .onHover { isHovering = $0 }
        .help(row.entry.path)
    }

    private var directory: String {
        (row.entry.path as NSString).deletingLastPathComponent
    }
}

/// "Copy Path" for the full path, when the project's folder is known, and
/// "Copy Relative Path" for the path inside the project. For a file's
/// right-click menu in the Files and Changes panels.
struct CopyPathButtons: View {
    let path: String
    let root: String?

    var body: some View {
        if let root {
            Button("Copy Path") { Self.copy(URL(fileURLWithPath: root).appendingPathComponent(path).path) }
        }
        Button("Copy Relative Path") { Self.copy(path) }
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
