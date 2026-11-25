import Foundation

/// Every file in a project, as paths relative to its folder. Git-ignored
/// files and the .git folder are left out.
public struct FileListing: Codable, Sendable, Equatable {
    public var paths: [String]
    /// True when the project has more files than Bench lists.
    public var truncated: Bool

    public init(paths: [String], truncated: Bool) {
        self.paths = paths
        self.truncated = truncated
    }
}

/// One file's contents, as the file viewer shows it.
public enum FileContent: Codable, Sendable, Equatable {
    case text(String)
    case image(Data)
    case binary(size: Int)
    case tooLarge(size: Int)
    case missing
}

/// A listing arranged as folders, for the Files sidebar.
public struct FileTree: Sendable, Equatable {
    public struct Entry: Sendable, Equatable, Hashable {
        public var name: String
        public var path: String
        public var isDirectory: Bool
    }

    /// One visible line in the sidebar.
    public struct Row: Identifiable, Sendable, Hashable {
        public var entry: Entry
        public var depth: Int
        public var id: String { entry.path }
    }

    /// Each folder's contents by its path ("" is the project folder):
    /// folders first, then files, in Finder order.
    public let children: [String: [Entry]]
    public let fileCount: Int

    public init(paths: [String]) {
        var found: [String: [String: Bool]] = [:]
        for path in paths {
            let parts = path.split(separator: "/").map(String.init)
            var parent = ""
            for (index, name) in parts.enumerated() {
                let isDirectory = index < parts.count - 1
                found[parent, default: [:]][name] = (found[parent]?[name] ?? false) || isDirectory
                parent = parent.isEmpty ? name : parent + "/" + name
            }
        }
        var children: [String: [Entry]] = [:]
        for (parent, names) in found {
            children[parent] = names.map { name, isDirectory in
                Entry(name: name, path: parent.isEmpty ? name : parent + "/" + name, isDirectory: isDirectory)
            }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
        self.children = children
        fileCount = paths.count
    }

    /// The lines to show with these folders open.
    public func rows(expanded: Set<String>) -> [Row] {
        var rows: [Row] = []
        func add(_ parent: String, depth: Int) {
            for entry in children[parent] ?? [] {
                rows.append(Row(entry: entry, depth: depth))
                if entry.isDirectory, expanded.contains(entry.path) { add(entry.path, depth: depth + 1) }
            }
        }
        add("", depth: 0)
        return rows
    }

    /// Files whose path contains the query, flat, for the filter field.
    public func rows(matching query: String, limit: Int = 500) -> [Row] {
        var rows: [Row] = []
        func add(_ parent: String) {
            for entry in children[parent] ?? [] where rows.count < limit {
                if entry.isDirectory {
                    add(entry.path)
                } else if entry.path.localizedStandardContains(query) {
                    rows.append(Row(entry: entry, depth: 0))
                }
            }
        }
        add("")
        return rows
    }
}

extension FileContent {
    /// "12 KB"
    public static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
