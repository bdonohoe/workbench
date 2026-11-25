import Foundation
import OSLog

/// A timeline of how a chat opens, for finding out why one sits empty. Each
/// line says how long after launch a step happened. It holds steps, counts,
/// and sizes, and never conversation text, paths, or project names.
///
/// With a file set (the Mac sets one) it's kept there, trimmed so it stays
/// small. Without one, it only goes to the system log.
public enum ChatTiming {
    /// How big the file can get at launch, and how much of it stays after that.
    static let maxBytes: UInt64 = 512 * 1024
    static let keptBytes = 256 * 1024

    private static let log = Logger(subsystem: "me.birchtree.Bench", category: "ChatTiming")
    private static let queue = DispatchQueue(label: "Bench.ChatTiming", qos: .utility)
    private static let started = ContinuousClock.now

    // All only touched on `queue`.
    nonisolated(unsafe) private static var file: URL?
    nonisolated(unsafe) private static var noted: Set<String> = []
    /// Lines since the file was last trimmed, so a Mac left running for
    /// weeks trims it now and then, not only at launch.
    nonisolated(unsafe) private static var linesSinceTrim = 0

    /// Starts the clock and the file. Call as early in launch as possible.
    public static func start(file url: URL?, version: String) {
        _ = started
        queue.async {
            file = url
            if let url {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                trim(url)
            }
        }
        note("app launched", details: "version=\(version)")
    }

    /// Adds a step. With `once`, only the first since `begin` for that tab counts.
    public static func note(_ step: String, tab: UUID? = nil, details: String = "", once: Bool = false) {
        let elapsed = (ContinuousClock.now - started).seconds
        let date = Date.now
        queue.async {
            if once, !noted.insert("\(tab?.uuidString ?? "")|\(step)").inserted { return }
            let text = line(date: date, elapsed: elapsed, step: step, tab: tab, details: details)
            log.info("\(text, privacy: .public)")
            if let file {
                append(text, to: file)
                linesSinceTrim += 1
                if linesSinceTrim >= 2000 {
                    linesSinceTrim = 0
                    trim(file)
                }
            }
        }
    }

    /// A chat is opening, so its one-time steps can show up again.
    public static func begin(tab: UUID, details: String = "") {
        queue.async { noted = noted.filter { !$0.hasPrefix(tab.uuidString) } }
        note("chat opened", tab: tab, details: details)
    }

    static func line(date: Date, elapsed: Double, step: String, tab: UUID?, details: String) -> String {
        var parts = [date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .current)), String(format: "+%.2fs", elapsed)]
        if let tab { parts.append("tab=\(tab.uuidString.prefix(8))") }
        parts.append(step)
        if !details.isEmpty { parts.append(details) }
        return parts.joined(separator: " ")
    }

    private static func append(_ text: String, to url: URL) {
        let data = Data((text + "\n").utf8)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            try? data.write(to: url)
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    /// Keeps the newest part of a file that's grown too big, from a line start.
    static func trim(_ url: URL) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64,
              size > maxBytes, let data = try? Data(contentsOf: url) else { return }
        let tail = data.suffix(keptBytes)
        let start = tail.firstIndex(of: UInt8(ascii: "\n")).map { tail.index(after: $0) } ?? tail.startIndex
        try? Data(tail[start...]).write(to: url, options: .atomic)
    }
}

public extension Duration {
    /// The length in seconds.
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    /// The length in whole milliseconds, for a timeline.
    var milliseconds: Int { Int(seconds * 1000) }
}
