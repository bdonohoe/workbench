import CoreGraphics
import Testing
@testable import BenchKit

struct ChatTailTests {
    @Test func shortConversationsAreAllPlain() {
        for count in 0...24 { #expect(ChatTail.start(count: count) == 0) }
    }

    @Test func thePlainStackAlwaysHoldsEnoughTurns() {
        for count in 25...2_000 {
            let plain = count - ChatTail.start(count: count)
            #expect(plain >= ChatTail.least)
            #expect(plain < ChatTail.least + ChatTail.batch)
        }
    }

    @Test func turnsMoveToTheHistoryInBatches() {
        // One new turn at a time, the split only moves once per batch.
        let starts = (25...100).map { ChatTail.start(count: $0) }
        let moves = zip(starts, starts.dropFirst()).filter { $0 != $1 }
        #expect(moves.count == 5)
        #expect(moves.allSatisfy { $1 - $0 == ChatTail.batch })
    }

    @Test func historyChunksCoverEveryTurnOnce() {
        #expect(ChatTail.chunks(of: 0).isEmpty)
        for count in [1, 14, 15, 16, 60, 61, 1_999] {
            let chunks = ChatTail.chunks(of: count)
            #expect(chunks.flatMap { Array($0) } == Array(0..<count))
            #expect(chunks.allSatisfy { $0.count <= ChatTail.batch })
        }
    }

    @Test func historyChunksKeepTheirTurnsAsTheHistoryGrows() {
        // The history grows a batch at a time, so the chunks it already had
        // stay as they were, and keep the heights measured for them.
        let before = ChatTail.chunks(of: ChatTail.start(count: 70))
        let after = ChatTail.chunks(of: ChatTail.start(count: 85))
        #expect(after.count == before.count + 1)
        #expect(Array(after.prefix(before.count)) == before)
    }

    @Test func aChunkIsDrawnNearTheScreenAndDroppedFarFromIt() {
        // The screen shows 1000...1800 of the list.
        func reach(_ top: CGFloat, _ bottom: CGFloat) -> ChatTail.Reach {
            ChatTail.reach(top: top, bottom: bottom, screenTop: 1_000, screenBottom: 1_800)
        }
        #expect(reach(900, 1_200) == .near)        // on screen
        #expect(reach(0, 5_000) == .near)          // taller than the screen
        #expect(reach(-800, 0) == .near)           // just above it
        #expect(reach(2_500, 3_000) == .near)      // just below it
        #expect(reach(-3_000, -1_000) == .between) // neither drawn nor dropped
        #expect(reach(-9_000, -4_000) == .far)     // well above
        #expect(reach(6_500, 9_000) == .far)       // well below
    }

    @Test func drawingStartsBeforeDroppingDoes() {
        // Otherwise a chunk at one distance would be drawn and dropped in turn.
        #expect(ChatTail.drawWithin < ChatTail.dropBeyond)
    }
}
