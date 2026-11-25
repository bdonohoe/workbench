import Foundation
import Testing
@testable import Bench

/// What the usage reader takes from a transcript: the context size from
/// the newest assistant message, and Claude Code's note that you pressed
/// Escape, which is how a tab stuck on "working" gets unstuck.
@MainActor
struct TranscriptUsageReaderTests {
    private func transcript(_ lines: [String]) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bench-usage-\(UUID().uuidString).jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        return url.path
    }

    private func assistant(id: String, input: Int, cached: Int, output: Int) -> String {
        #"{"type":"assistant","timestamp":"2026-11-06T22:00:00.000Z","message":{"id":"\#(id)","role":"assistant","model":"claude-opus-5-5","content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":\#(input),"cache_read_input_tokens":\#(cached),"output_tokens":\#(output)}}}"#
    }

    private func read(_ reader: TranscriptUsageReader, _ path: String) async -> TranscriptInfo {
        await withCheckedContinuation { done in reader.update(path: path) { done.resume(returning: $0) } }
    }

    @Test func contextComesFromTheNewestMessage() async throws {
        let path = try transcript([assistant(id: "m1", input: 100, cached: 50, output: 10),
                                   assistant(id: "m2", input: 300, cached: 500, output: 20)])
        let info = await read(TranscriptUsageReader(), path)
        #expect(info.usage?.contextTokens == 820)
        #expect(info.usage?.outputTokens == 30)
        #expect(info.interruptedAt == nil)
    }

    @Test func anInterruptionIsNoticedWhenItIsAppended() async throws {
        let path = try transcript([assistant(id: "m1", input: 100, cached: 0, output: 10)])
        let reader = TranscriptUsageReader()
        #expect(await read(reader, path).interruptedAt == nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((#"{"type":"user","timestamp":"2026-11-06T22:05:00.000Z","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"# + "\n").utf8))
        try handle.close()
        let info = await read(reader, path)
        let at = try #require(info.interruptedAt)
        let expected = try #require(ISO8601DateFormatter().date(from: "2026-11-06T22:05:00Z"))
        #expect(abs(at.timeIntervalSince(expected)) < 1)
        // The usage from before is still there.
        #expect(info.usage?.contextTokens == 110)
    }

    @Test func editedFilesAreCollectedWithTheirLatestTime() async throws {
        func edit(_ tool: String, _ path: String, at time: String) -> String {
            #"{"type":"assistant","timestamp":"\#(time)","message":{"id":"\#(UUID().uuidString)","role":"assistant","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"\#(UUID().uuidString)","name":"\#(tool)","input":{"file_path":"\#(path)"}}],"usage":{"input_tokens":1,"output_tokens":1}}}"#
        }
        let path = try transcript([edit("Edit", "/Users/me/Apps/QuickReads Safari/popup.js", at: "2026-11-06T22:00:00.000Z"),
                                   edit("Read", "/Users/me/Apps/QuickReads Safari/README.md", at: "2026-11-06T22:01:00.000Z"),
                                   edit("Write", "/Users/me/Apps/QuickReads Firefox/popup.js", at: "2026-11-06T22:02:00.000Z"),
                                   edit("Edit", "/Users/me/Apps/QuickReads Safari/popup.js", at: "2026-11-06T22:03:00.000Z")])
        let info = await read(TranscriptUsageReader(), path)
        #expect(Set(info.editedFiles.keys) == ["/Users/me/Apps/QuickReads Safari/popup.js", "/Users/me/Apps/QuickReads Firefox/popup.js"])
        let latest = try #require(ISO8601DateFormatter().date(from: "2026-11-06T22:03:00Z"))
        #expect(abs((info.editedFiles["/Users/me/Apps/QuickReads Safari/popup.js"] ?? .distantPast).timeIntervalSince(latest)) < 1)
    }

    @Test func aTranscriptBiggerThanOneChunkIsReadWhole() async throws {
        // Past the four-megabyte chunk, so the reader goes round more than once.
        let filler = String(repeating: "x", count: 100_000)
        var lines: [String] = []
        for n in 0..<60 {
            lines.append(#"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"\#(filler)"}]},"n":\#(n)}"#)
            lines.append(assistant(id: "m\(n)", input: n, cached: 0, output: 1))
        }
        let path = try transcript(lines)
        let info = await read(TranscriptUsageReader(), path)
        #expect(info.usage?.contextTokens == 60)
        #expect(info.usage?.outputTokens == 60)
    }
}
