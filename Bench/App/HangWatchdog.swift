import Foundation

/// Watches for the app freezing (the beach ball) and, when the main thread
/// has been stuck for a few seconds, runs `/usr/bin/sample` on Workbench so
/// there's a record of what it was stuck on. Samples land in
/// `<support>/hangs/`, and the newest few are kept.
///
/// It runs on a thread of its own, since a frozen main thread can't notice
/// that it's frozen. It's nonisolated because this target makes types
/// main-actor by default, and main-actor code run on another thread stops
/// the app.
nonisolated final class HangWatchdog: @unchecked Sendable {
    static let shared = HangWatchdog()

    /// How long the main thread is stuck before a sample is taken.
    static let threshold: TimeInterval = 3
    /// How long `sample` watches for.
    static let sampleSeconds = 3
    /// At most one sample this often, so a run of freezes doesn't fill the disk.
    static let minimumGap: TimeInterval = 10 * 60
    /// How many samples to keep.
    static let kept = 5

    static var folder: URL { BenchPaths.support.appendingPathComponent("hangs", isDirectory: true) }

    private let lock = NSLock()
    private var lastBeat = Date()
    private var started = false

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard !started else { return }
        started = true
        let thread = Thread { [self] in watch() }
        thread.name = "HangWatchdog"
        thread.qualityOfService = .utility
        thread.start()
    }

    private func beat() {
        lock.lock(); lastBeat = Date(); lock.unlock()
    }

    private var sinceBeat: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(lastBeat)
    }

    private func watch() {
        var lastSample = Date.distantPast
        var hang: (file: URL, start: Date)?
        while true {
            DispatchQueue.main.async { [self] in beat() }
            Thread.sleep(forTimeInterval: 0.5)
            let stuck = sinceBeat
            if stuck >= Self.threshold, hang == nil, Date().timeIntervalSince(lastSample) >= Self.minimumGap {
                lastSample = Date()
                let start = Date().addingTimeInterval(-stuck)
                if let file = takeSample(stuckFor: stuck) { hang = (file, start) }
            } else if stuck < 1, let finished = hang {
                // Unstuck: note how long the freeze lasted.
                let seconds = Date().timeIntervalSince(finished.start)
                append("\nMain thread was unresponsive for about \(Int(seconds.rounded())) seconds.\n", to: finished.file)
                NSLog("Bench: recovered from a \(Int(seconds.rounded()))s hang; sample at \(finished.file.path)")
                hang = nil
            }
        }
    }

    /// Runs `sample` on this process and returns the file it wrote.
    private func takeSample(stuckFor stuck: TimeInterval) -> URL? {
        let folder = Self.folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let file = folder.appendingPathComponent("hang-\(stamp).txt")
        // posix_spawn and a blocking waitpid keep this entirely on the
        // watchdog's thread, with nothing that needs the stuck main thread.
        let argv = ["/usr/bin/sample", String(ProcessInfo.processInfo.processIdentifier), String(Self.sampleSeconds), "-mayDie", "-file", file.path]
        var cArgv = argv.map { strdup($0) } + [nil]
        defer { cArgv.forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, argv[0], nil, nil, &cArgv, environ)
        guard result == 0 else {
            NSLog("Bench: main thread stuck for \(Int(stuck))s, but sample couldn't run: \(String(cString: strerror(result)))")
            return nil
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1, errno == EINTR {}
        guard FileManager.default.fileExists(atPath: file.path) else {
            NSLog("Bench: main thread stuck for \(Int(stuck))s, but sample wrote nothing (status \(status))")
            return nil
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        append("\nWorkbench \(version) (\(build)). Sampled after the main thread was stuck for \(Int(stuck)) seconds.\n", to: file)
        NSLog("Bench: main thread stuck for \(Int(stuck))s; sampled to \(file.path)")
        prune(folder)
        return file
    }

    private func append(_ text: String, to file: URL) {
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(text.utf8))
    }

    /// Keeps the newest few samples. The names sort by date.
    private func prune(_ folder: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let samples = files.filter { $0.lastPathComponent.hasPrefix("hang-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in samples.dropFirst(Self.kept) { try? FileManager.default.removeItem(at: old) }
    }
}
