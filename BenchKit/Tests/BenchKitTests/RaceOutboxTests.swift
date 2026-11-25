import Foundation
import Testing
@testable import BenchKit

/// What's sent while the race has no socket yet waits, in order.
@Suite struct RaceOutboxTests {
    @Test func drainsInOrderAndEmpties() {
        var outbox = RaceOutbox()
        let session = UUID()
        outbox.append(.reply(sessionID: session, text: "one"))
        outbox.append(.ping)
        outbox.append(.reply(sessionID: session, text: "two"))
        let texts = outbox.drain().map { message -> String in
            switch message {
            case .reply(_, let text): text
            case .ping: "ping"
            default: "other"
            }
        }
        #expect(texts == ["one", "ping", "two"])
        #expect(outbox.drain().isEmpty)
    }

    @Test func droppedRepliesNameTheirSessions() {
        var outbox = RaceOutbox()
        let session = UUID()
        outbox.append(.ping)
        outbox.append(.answer(sessionID: session, allow: true))
        #expect(outbox.drain().compactMap(\.sessionIDIfReply) == [session])
    }
}
