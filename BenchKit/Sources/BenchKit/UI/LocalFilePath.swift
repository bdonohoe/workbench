import Foundation

/// Finds the file a piece of inline code in a reply points at, if any.
/// Claude writes paths as `/Users/…/report.png`, `~/Library/…`, a path
/// inside the project like `Bench/App/BenchApp.swift`, or one with a line
/// on the end like `Makefile:29`. Anything else, or a path to nothing on
/// disk, is not a file.
public enum LocalFilePath {
    /// What's at a path: nothing, a file, or a folder.
    public enum Entry { case missing, file, folder }

    /// The full path of the file or folder `text` names, or nil when it
    /// names none. `root` is the project folder relative paths count from;
    /// `lookup` says what's at a path, and is a parameter so tests needn't
    /// touch the disk.
    public static func resolve(
        _ text: String,
        root: String?,
        home: String = NSHomeDirectory(),
        lookup: (String) -> Entry = onDisk
    ) -> String? {
        var path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        // A bare word like `Makefile` or `README` can be a file, but a bare
        // word that happens to match a folder (`build`, `main`, `vendor`)
        // is far more often a command or a branch, so it isn't one.
        // Written `build/`, it's a folder.
        let bareWord = !path.contains("/") && !path.contains(".")
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if path.hasPrefix("~/") || path == "~" {
            path = home + path.dropFirst()
        }
        for candidate in [path] + withoutLineNumbers(path) {
            guard let full = fullPath(candidate, root: root) else { continue }
            switch lookup(full) {
            case .file: return full
            case .folder where !bareWord: return full
            case .folder, .missing: continue
            }
        }
        return nil
    }

    public static func onDisk(_ path: String) -> Entry {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) else { return .missing }
        return isFolder.boolValue ? .folder : .file
    }

    /// `Makefile:29` and `Makefile:29:5` without their line and column.
    /// Both forms are tried, since a file can have a colon in its name.
    private static func withoutLineNumbers(_ path: String) -> [String] {
        var found: [String] = []
        var current = Substring(path)
        for _ in 0..<2 {
            guard let colon = current.lastIndex(of: ":"),
                  colon > current.startIndex,
                  !current[current.index(after: colon)...].isEmpty,
                  current[current.index(after: colon)...].allSatisfy(\.isNumber) else { break }
            current = current[..<colon]
            found.append(String(current))
        }
        return found
    }

    private static func fullPath(_ path: String, root: String?) -> String? {
        if path.hasPrefix("/") { return path }
        guard let root else { return nil }
        return (root.hasSuffix("/") ? root : root + "/") + path
    }
}
