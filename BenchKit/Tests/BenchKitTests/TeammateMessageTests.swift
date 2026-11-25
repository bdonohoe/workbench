import Foundation
import Testing
@testable import BenchKit

/// Messages from agent-team teammates reach the lead's transcript as user
/// entries, wrapped in `<teammate-message>` tags. They aren't yours.
@Suite struct TeammateMessageTests {
    private func line(_ entry: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: entry)
    }

    private func userLine(_ content: Any, id: String = "t") -> Data {
        line(["type": "user", "uuid": id, "timestamp": "2026-11-13T00:25:04.000Z", "message": ["role": "user", "content": content]])
    }

    private let teammate = """
        <teammate-message teammate_id="pr3-graceful-shutdown" color="pink">
        {"type":"idle_notification","from":"pr3-graceful-shutdown","idleReason":"available","result":"PR #181 now cancels every straggler"}
        </teammate-message>
        """

    @Test func aTeammateMessageAloneIsNotYours() {
        #expect(TranscriptParser.messages(in: userLine(teammate)).isEmpty)
    }

    @Test func aTeammateMessageAfterAPreambleIsNotYours() {
        let text = "Another Claude session sent a message while you were working:\n" + teammate
        #expect(TranscriptParser.messages(in: userLine(text)).isEmpty)
    }

    @Test func teammateMessagesInTextBlocksAreNotYours() {
        let blocks: [[String: Any]] = [
            ["type": "text", "text": "Messages from your team:"],
            ["type": "text", "text": teammate],
            ["type": "text", "text": teammate],
        ]
        #expect(TranscriptParser.messages(in: userLine(blocks)).isEmpty)
    }

    @Test func aQueuedTeammateMessageIsNotYours() {
        let queued = line(["type": "queue-operation", "operation": "enqueue", "timestamp": "2026-11-13T00:25:04.000Z",
                           "content": "\n" + teammate])
        #expect(TranscriptParser.messages(in: queued, options: .init(keepsQueue: true)).isEmpty)
        let attached = line(["type": "attachment", "uuid": "a", "timestamp": "2026-11-13T00:25:04.000Z",
                             "attachment": ["type": "queued_command", "prompt": "Note:\n" + teammate, "origin": ["kind": "human"]]])
        #expect(TranscriptParser.messages(in: attached).isEmpty)
    }

    @Test func yourMessageThatMentionsTheTagIsStillYours() {
        let messages = TranscriptParser.messages(in: userLine("Why do `<teammate-message>` tags show up in the chat?"))
        #expect(messages.count == 1)
        #expect(messages.first?.role == .user)
    }
}
