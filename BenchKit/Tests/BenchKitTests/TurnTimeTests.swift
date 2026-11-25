import Foundation
import Testing
@testable import BenchKit

/// The note after a long run: how long Claude worked and when it finished.
@Suite struct TurnTimeTests {
    private func line(milliseconds: Int) -> Data {
        let entry: [String: Any] = ["type": "system", "subtype": "turn_duration", "durationMs": milliseconds,
                                    "uuid": "t", "timestamp": "2026-11-09T22:50:00.000Z"]
        return try! JSONSerialization.data(withJSONObject: entry)
    }

    @Test func aLongRunLeavesANote() {
        let messages = TranscriptParser.messages(in: line(milliseconds: 1_223_400), options: .init(keepsTurnTimes: true))
        #expect(messages.count == 1)
        #expect(messages.first?.role == .system)
        #expect(messages.first?.worked == 1223.4)
        #expect(messages.first?.text == TurnTime.summary(id: "t", worked: 1223.4))
        #expect(messages.first?.text.hasSuffix(" for 20m 23s") == true)
        #expect(messages.first?.at != nil)
    }

    @Test func aShortRunLeavesNone() {
        #expect(TranscriptParser.messages(in: line(milliseconds: 9_876), options: .init(keepsTurnTimes: true)).isEmpty)
    }

    @Test func readersThatDidNotAskGetNone() {
        #expect(TranscriptParser.messages(in: line(milliseconds: 1_223_400)).isEmpty)
    }

    @Test func durationsReadTheWayTheTerminalPrintsThem() {
        #expect(TurnTime.duration(45) == "45s")
        #expect(TurnTime.duration(1223) == "20m 23s")
        #expect(TurnTime.duration(3840) == "1h 4m")
    }

    @Test func aRunKeepsItsVerbAndRunsDiffer() {
        #expect(TurnTime.verb(for: "d19bef26-7244") == TurnTime.verb(for: "d19bef26-7244"))
        #expect(TurnTime.verbs.contains(TurnTime.verb(for: "")))
        let seen = Set((0..<200).map { TurnTime.verb(for: "run-\($0)") })
        #expect(seen.count == TurnTime.verbs.count)
    }

    @Test func anEarlierDayIsNamed() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let now = Date(timeIntervalSince1970: 1_794_000_000)
        #expect(!TurnTime.finished(now, now: now, calendar: calendar).contains(","))
        #expect(TurnTime.finished(now.addingTimeInterval(-3 * 86_400), now: now, calendar: calendar).contains(","))
    }

    @Test func theNoteSurvivesTheTripToThePhone() throws {
        let message = TranscriptMessage(id: "t", role: .system, text: "Worked for 20m 23s", worked: 1223)
        let decoded = try JSONDecoder().decode(TranscriptMessage.self, from: JSONEncoder().encode(message))
        #expect(decoded.worked == 1223)
    }
}
