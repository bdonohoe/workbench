import BenchKit
import CoreServices
import Foundation
import Observation

/// Keeps a live list of a project's files while something is showing
/// them: the Files sidebar, an open file, or a remote Mac.
@Observable
final class FileListMonitor {
    let root: URL
    private(set) var listing: FileListing?
    private(set) var tree: FileTree?
    /// Goes up whenever anything under the folder changes, so open files
    /// know to read themselves again.
    private(set) var revision = 0
    /// Folders open in the Files sidebar, kept while you look elsewhere.
    var expanded: Set<String> = []

    @ObservationIgnored private var users = 0
    @ObservationIgnored private var stream: FSEventStreamRef?
    @ObservationIgnored private var pendingList: Task<Void, Never>?
    @ObservationIgnored private var pendingRevision: Task<Void, Never>?
    @ObservationIgnored private var listTask: Task<Void, Never>?
    @ObservationIgnored private var needsAnotherList = false
    /// Whether the folder is being watched right now: true from the first
    /// `retain()` until the last `release()`.
    var isWatching: Bool { stream != nil }

    init(root: URL) {
        self.root = root
    }

    deinit {
        MainActor.assumeIsolated { stopWatching() }
    }

    /// Call when something starts showing these files, and `release()`
    /// when it stops. The folder is watched while anything is.
    func retain() {
        users += 1
        if users == 1 { startWatching() }
    }

    func release() {
        users = max(0, users - 1)
        if users == 0 { stopWatching() }
    }

    /// Holds the monitor for as long as the calling task runs, for
    /// `.task(id:)` in views.
    func hold() async {
        retain()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
        release()
    }

    // MARK: Listing

    private func listSoon() {
        pendingList?.cancel()
        pendingList = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.list()
        }
    }

    private func bumpSoon() {
        pendingRevision?.cancel()
        pendingRevision = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.revision += 1
        }
    }

    private func list() {
        guard listTask == nil else {
            needsAnotherList = true
            return
        }
        let root = root
        listTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { await FileLister.list(root) }.value
            guard let self else { return }
            if self.listing != result {
                let tree = await Task.detached(priority: .userInitiated) { FileTree(paths: result.paths) }.value
                self.listing = result
                self.tree = tree
            }
            self.listTask = nil
            if self.needsAnotherList {
                self.needsAnotherList = false
                self.list()
            }
        }
    }

    // MARK: Watching

    private func startWatching() {
        guard stream == nil else { return }
        list()
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let monitor = Unmanaged<FileListMonitor>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            var touched = false
            var reshaped = false
            let reshaping = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
                | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagMustScanSubDirs)
            for index in 0..<min(count, list.count) {
                let path = list[index]
                // Git's own bookkeeping doesn't change what's in the folder,
                // except for .gitignore rules, which live outside .git.
                if path.contains("/.git/") || path.hasSuffix("/.git") { continue }
                touched = true
                if flags[index] & reshaping != 0 || path.hasSuffix("/.gitignore") { reshaped = true }
            }
            guard touched else { return }
            MainActor.assumeIsolated {
                monitor.bumpSoon()
                if reshaped { monitor.listSoon() }
            }
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.15,
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func stopWatching() {
        pendingList?.cancel()
        pendingRevision?.cancel()
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}

/// One file monitor per project, created on demand.
@Observable
final class FileListMonitors {
    // Created lazily from view bodies, so changes here must not invalidate views.
    @ObservationIgnored private var monitors: [UUID: FileListMonitor] = [:]

    func monitor(for project: Project) -> FileListMonitor {
        if let existing = monitors[project.id], existing.root == project.url { return existing }
        let monitor = FileListMonitor(root: project.url)
        monitors[project.id] = monitor
        return monitor
    }

    func prune(keeping ids: Set<UUID>) {
        for id in monitors.keys where !ids.contains(id) { monitors[id] = nil }
    }
}

// MARK: - Reading the folder

nonisolated enum FileLister {
    /// More than this and the sidebar would be more noise than help.
    static let limit = 20_000

    /// Git's view of the folder when it's a repository (tracked files plus
    /// new ones, minus ignored ones), else a walk that skips hidden files.
    /// Repositories nested inside either are listed by their own git, so
    /// their ignored files (node_modules, build output) stay out too.
    static func list(_ root: URL) async -> FileListing {
        var paths: [String] = []
        let complete = await collect(root, prefix: "", into: &paths)
        return FileListing(paths: paths, truncated: !complete)
    }

    /// Adds the files under `folder` to `paths`, each prefixed with
    /// `prefix`. Returns false once the limit is reached.
    private static func collect(_ folder: URL, prefix: String, into paths: inout [String]) async -> Bool {
        guard let data = try? await GitClient(root: folder).run(["ls-files", "-z", "--cached", "--others", "--exclude-standard"]) else {
            return await walk(folder, prefix: prefix, into: &paths)
        }
        let fileManager = FileManager()
        var seen = Set<String>()
        var nested: [String] = []
        for slice in data.split(separator: 0) {
            let path = String(decoding: slice, as: UTF8.self)
            guard !seen.contains(path) else { continue }
            seen.insert(path)
            // Deleted files stay in git's index until the change is
            // committed. Folders are submodules or repositories inside
            // this one, which git doesn't look into.
            var isDirectory: ObjCBool = false
            let url = folder.appendingPathComponent(path)
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                if isRepository(url, fileManager) { nested.append(trimmingSlash(path)) }
                continue
            }
            paths.append(prefix + path)
            if paths.count >= limit { return false }
        }
        for path in nested {
            guard await collect(folder.appendingPathComponent(path), prefix: prefix + path + "/", into: &paths) else { return false }
        }
        return true
    }

    /// Every regular file under the folder, skipping hidden ones, a level
    /// at a time so every top-level folder shows up even when the limit
    /// cuts the list short.
    private static func walk(_ root: URL, prefix: String, into paths: inout [String]) async -> Bool {
        let fileManager = FileManager()
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isPackageKey]
        var queue: [(url: URL, path: String)] = [(root, prefix)]
        var index = 0
        while index < queue.count {
            let (folder, folderPath) = queue[index]
            index += 1
            guard let items = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                   options: [.skipsHiddenFiles]) else { continue }
            for url in items {
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                let path = folderPath + url.lastPathComponent
                if values.isRegularFile == true {
                    paths.append(path)
                    if paths.count >= limit { return false }
                } else if values.isDirectory == true, values.isPackage != true {
                    if isRepository(url, fileManager) {
                        guard await collect(url, prefix: path + "/", into: &paths) else { return false }
                    } else {
                        queue.append((url, path + "/"))
                    }
                }
            }
        }
        return true
    }

    /// A folder with its own .git: a folder for a clone, a file for a
    /// worktree or submodule.
    private static func isRepository(_ folder: URL, _ fileManager: FileManager) -> Bool {
        fileManager.fileExists(atPath: folder.appendingPathComponent(".git").path)
    }

    private static func trimmingSlash(_ path: String) -> String {
        path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

nonisolated enum FileReader {
    /// Text past this is too slow to show and rarely worth reading here.
    static let textLimit = 2 << 20
    static let imageLimit = 16 << 20
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "tif", "bmp", "ico", "icns"]

    static func read(_ url: URL, imageLimit: Int = imageLimit) -> FileContent {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return .missing }
        let size = (attributes[.size] as? Int) ?? 0
        if attributes[.type] as? FileAttributeType == .typeDirectory { return .binary(size: 0) }
        if imageExtensions.contains(url.pathExtension.lowercased()) {
            guard size <= imageLimit else { return .tooLarge(size: size) }
            guard let data = try? Data(contentsOf: url) else { return .missing }
            return .image(data)
        }
        guard size <= textLimit else { return .tooLarge(size: size) }
        guard let data = try? Data(contentsOf: url) else { return .missing }
        // A zero byte early on is the usual sign of a binary file.
        if data.prefix(8000).contains(0) { return .binary(size: size) }
        if let text = String(data: data, encoding: .utf8) { return .text(text) }
        return .binary(size: size)
    }
}
