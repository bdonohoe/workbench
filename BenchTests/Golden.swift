import Foundation
import Testing

/// Compares what the code produces now with a saved copy of what it
/// produced before, so a refactor that changes the result fails a test.
/// The recorded sessions are BenchKit's (see its Fixtures/README.md).
/// `BENCH_RECORD_GOLDENS=1` writes the saved copies instead of checking.
nonisolated enum Golden {
    private static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    static let fixtures = folder.deletingLastPathComponent().appendingPathComponent("BenchKit/Tests/BenchKitTests/Fixtures")
    private static let isRecording = ProcessInfo.processInfo.environment["BENCH_RECORD_GOLDENS"] != nil

    static func fixture(_ path: String) -> URL { fixtures.appendingPathComponent(path) }

    /// The lines of a recorded `.jsonl` file, as JSON objects.
    static func entries(_ path: String) throws -> [[String: Any]] {
        try Data(contentsOf: fixture(path)).split(separator: UInt8(ascii: "\n")).compactMap {
            try JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]
        }
    }

    static func check(_ text: String, _ name: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let file = folder.appendingPathComponent("Goldens").appendingPathComponent(name)
        if isRecording {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
            return
        }
        let saved = try String(contentsOf: file, encoding: .utf8)
        guard saved != text else { return }
        let was = saved.components(separatedBy: "\n"), now = text.components(separatedBy: "\n")
        let line = Array(zip(was, now)).firstIndex { $0 != $1 } ?? min(was.count, now.count)
        Issue.record("""
            \(name) no longer matches at line \(line + 1).
            was: \(line < was.count ? was[line] : "(end)")
            now: \(line < now.count ? now[line] : "(end)")
            """, sourceLocation: sourceLocation)
    }

    /// Any Encodable value as stable, readable JSON.
    static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return String(decoding: try encoder.encode(value), as: UTF8.self) + "\n"
    }
}
