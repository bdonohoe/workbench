import BenchKit
import Foundation

/// Answers the `bench` command line tool, which Workbench puts on PATH in
/// every tab so you or Claude can drive the app from a shell.
///
/// The tool writes `requests/<id>.request`: "cli" on the first line, then
/// what `BenchRequest` reads (where it ran and its arguments). Workbench
/// deletes it, leaves `<id>.working` holding its process id so the tool
/// knows to keep waiting, acts on it, and writes `<id>.reply`: a status on
/// the first line ("ok", "error", "usage", or "stdin" to be asked again
/// with standard input), then the text the tool prints. What each command
/// does is in `BenchCommandRunner`.
final class ProjectRequests {
    private static let support = BenchPaths.support
    static let folder = support.appendingPathComponent("requests")

    /// Where the tool lives inside the app, for PATH.
    static var toolFolder: String? {
        Bundle.main.resourceURL?.appendingPathComponent("bench-cli").path
    }

    private let runner: BenchCommandRunner
    private var source: DispatchSourceFileSystemObject?

    init(runner: BenchCommandRunner) {
        self.runner = runner
        let folder = Self.folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Requests from before Workbench opened were given up on long ago.
        for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: file)
        }
        AgentSessions.publishCommands()
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in self?.read() }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    deinit { source?.cancel() }

    private func read() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "request" {
            handle(file)
        }
    }

    private func handle(_ file: URL) {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: file)
        let reply = file.deletingPathExtension().appendingPathExtension("reply")
        let firstBreak = text.firstIndex(of: "\n") ?? text.endIndex
        let command = String(text[..<firstBreak])
        guard command == "cli" else {
            // A `bench` script from an older copy of Workbench.
            Self.write(BenchReply(status: .error, text: "This bench command is from an older Workbench. Open a new tab to get the current one."), to: reply)
            return
        }
        let request = BenchRequest.parse(String(text[text.index(after: firstBreak)...]))
        // Some commands take a while: making a worktree, waiting on an
        // agent. This tells the tool the request was picked up, and it
        // disappears if the tool is interrupted.
        let working = file.deletingPathExtension().appendingPathExtension("working")
        try? "\(ProcessInfo.processInfo.processIdentifier)\n".write(to: working, atomically: true, encoding: .utf8)
        Task { [runner] in
            let answer = await runner.run(request) { FileManager.default.fileExists(atPath: working.path) }
            // The tool takes that file away when it's interrupted, and
            // then nobody is left to read an answer.
            if FileManager.default.fileExists(atPath: working.path) { Self.write(answer, to: reply) }
        }
    }

    private static func write(_ answer: BenchReply, to reply: URL) {
        try? "\(answer.status.rawValue)\n\(answer.text)\n".write(to: reply, atomically: true, encoding: .utf8)
    }
}
