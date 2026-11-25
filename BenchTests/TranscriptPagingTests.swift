import BenchKit
import Foundation
import Testing
@testable import Bench

/// Paging back through a long conversation on the phone, including past
/// the messages the Mac let go of to save memory while the session
/// stayed open.
@MainActor
struct TranscriptPagingTests {
    private func transcript(count: Int) throws -> (path: String, ids: [String]) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bench-paging-\(UUID().uuidString).jsonl")
        var ids: [String] = []
        var text = ""
        for n in 0..<count {
            let id = String(format: "%08X-0000-4000-8000-%012X", n, n)
            ids.append(id)
            text += #"{"type":"user","uuid":"\#(id)","timestamp":"2026-11-06T22:00:00.000Z","message":{"role":"user","content":[{"type":"text","text":"message \#(n)"}]}}"# + "\n"
        }
        try Data(text.utf8).write(to: url)
        return (url.path, ids)
    }

    private func opening(_ streamer: TranscriptStreamer, tab: UUID, path: String) async -> ([TranscriptMessage], Bool) {
        await withCheckedContinuation { done in streamer.opening(tabID: tab, path: path) { done.resume(returning: ($0, $1)) } }
    }

    private func poll(_ streamer: TranscriptStreamer, tab: UUID, path: String) async {
        await withCheckedContinuation { done in streamer.poll(tabID: tab, path: path, always: true) { _, _ in done.resume() } }
    }

    private func earlier(_ streamer: TranscriptStreamer, tab: UUID, path: String, before id: String) async -> ([TranscriptMessage], Bool) {
        await withCheckedContinuation { done in
            streamer.earlier(tabID: tab, path: path, before: id, count: 240) { done.resume(returning: ($0, $1)) }
        }
    }

    /// Pages back from `first` until the start, returning every id seen.
    private func pageToTheStart(_ streamer: TranscriptStreamer, tab: UUID, path: String, from first: String) async -> [String] {
        var ids = [first]
        var more = true
        var rounds = 0
        while more, rounds < 100 {
            rounds += 1
            let (page, hasMore) = await earlier(streamer, tab: tab, path: path, before: ids[0])
            if page.isEmpty { break }
            ids = page.map(\.id) + ids
            more = hasMore
        }
        return ids
    }

    @Test func theOpeningIsTheEndAndPagingReachesTheStart() async throws {
        let (path, ids) = try transcript(count: 1000)
        let streamer = TranscriptStreamer()
        let tab = UUID()
        let (opening, hasMore) = await opening(streamer, tab: tab, path: path)
        #expect(opening.count == TranscriptStreamer.openingLimit)
        #expect(opening.last?.id == ids.last)
        #expect(hasMore)
        let all = await pageToTheStart(streamer, tab: tab, path: path, from: opening[0].id)
        #expect(all.count == ids.count - opening.count + 1)
        #expect(all.first == ids.first)
    }

    @Test func pagingWorksPastMessagesLetGoOf() async throws {
        // More than the streamer keeps for a live session, so a poll trims.
        let (path, ids) = try transcript(count: 3000)
        let streamer = TranscriptStreamer()
        let tab = UUID()
        let (opening, _) = await opening(streamer, tab: tab, path: path)
        await poll(streamer, tab: tab, path: path)
        let all = await pageToTheStart(streamer, tab: tab, path: path, from: opening[0].id)
        #expect(all.first == ids.first)
        #expect(all.count == ids.count - opening.count + 1)
        #expect(all == Array(ids[0...(ids.count - opening.count)]))
    }
}
