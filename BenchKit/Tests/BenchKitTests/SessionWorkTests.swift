import Foundation
import Testing
@testable import BenchKit

struct SessionWorkTests {
    @Test func trailAndNoteRoundTrip() throws {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let session = CompanionSession(id: UUID(), title: "T", activity: .working,
                                       trail: [ToolAction(id: "a", text: "Editing Theme.swift", at: at)],
                                       note: "Looking at the sidebar.", noteAt: at, promptAt: at.addingTimeInterval(-60))
        let data = try JSONEncoder().encode(session)
        let back = try JSONDecoder().decode(CompanionSession.self, from: data)
        #expect(back == session)
        #expect(back.trail?.first?.pastText == "Edited Theme.swift")
    }

    @Test func olderMacsLeaveThemOut() throws {
        let json = #"{"id":"\#(UUID().uuidString)","title":"T","activity":"working","isAllowOrDeny":false}"#
        let session = try JSONDecoder().decode(CompanionSession.self, from: Data(json.utf8))
        #expect(session.trail == nil)
        #expect(session.note == nil)
        #expect(session.promptAt == nil)
    }
}
