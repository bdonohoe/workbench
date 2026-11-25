import Foundation
import Testing
@testable import BenchKit

@Suite struct QueueSyncTests {
    let queuedAt = Date(timeIntervalSince1970: 1_800_000_000)

    func item(_ id: UUID) -> QueueItem { QueueItem(id: id, sealed: "s", addedAt: queuedAt) }
    func day(_ days: Double, extra: TimeInterval = 0) -> Date { queuedAt.addingTimeInterval(days * 86_400 + extra) }

    @Test func waitingWhenListed() {
        let id = UUID()
        #expect(QueueSync.state(of: id, items: [item(id)], taken: []) == .waiting)
    }

    @Test func startedWhenTaken() {
        let id = UUID()
        #expect(QueueSync.state(of: id, items: [], taken: [id]) == .started)
    }

    @Test func expiredWhenNeither() {
        #expect(QueueSync.state(of: UUID(), items: [item(UUID())], taken: [UUID()]) == .expired)
    }

    @Test func editOfTakenIsStarted() {
        let id = UUID()
        #expect(QueueSync.state(of: id, items: [], taken: [id]) == .started)
    }

    @Test func noNoteBeforeDay12() {
        #expect(QueueSync.expiryNote(queuedAt: queuedAt, now: queuedAt) == nil)
        #expect(QueueSync.expiryNote(queuedAt: queuedAt, now: day(11, extra: 86_399)) == nil)
    }

    @Test func noteOnDay12() {
        #expect(QueueSync.expiryNote(queuedAt: queuedAt, now: day(12)) == "Expires in 2 days")
    }

    @Test func noteOnDay13() {
        #expect(QueueSync.expiryNote(queuedAt: queuedAt, now: day(13)) == "Expires tomorrow")
    }

    @Test func noteOnDay14() {
        #expect(QueueSync.expiryNote(queuedAt: queuedAt, now: day(14)) == "Expires today")
        #expect(QueueSync.expiryNote(queuedAt: queuedAt, now: day(20)) == "Expires today")
    }
}
