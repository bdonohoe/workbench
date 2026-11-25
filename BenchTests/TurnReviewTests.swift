import BenchKit
import Foundation
import Testing
@testable import Bench

/// A turn's changes, read from a transcript file for the review tab.
@Suite struct TurnReviewTests {
    private func line(_ entry: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: entry), as: UTF8.self)
    }

    private func prompt(_ id: String, _ text: String) -> String {
        line(["type": "user", "uuid": id, "message": ["role": "user", "content": text]])
    }

    private func edit(_ id: String, path: String) -> [String] {
        [line(["type": "assistant", "uuid": id,
               "message": ["content": [["type": "tool_use", "id": "use-" + id, "name": "Edit",
                                        "input": ["file_path": path, "old_string": "a", "new_string": "b"]]]]]),
         line(["type": "user", "uuid": id + "-r",
               "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "use-" + id, "content": "ok"]]],
               "toolUseResult": ["filePath": path,
                                 "structuredPatch": [["oldStart": 3, "newStart": 3, "lines": [" x", "-a", "+b"]]]]])]
    }

    private func transcript(_ lines: [String]) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("turn-review-\(UUID().uuidString).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    @Test func theLatestTurnIsReadFromTheTranscript() throws {
        let path = try transcript([prompt("p1", "First")] + edit("e1", path: "/repo/A.swift")
                                  + [prompt("p2", "Second thing")] + edit("e2", path: "/repo/Sources/B.swift"))
        defer { try? FileManager.default.removeItem(atPath: path) }
        guard case .turn(let turn, let diff) = TurnReview.load(path: path, turnID: nil, root: "/repo") else {
            Issue.record("No turn read")
            return
        }
        #expect(turn.id == "p2")
        #expect(turn.prompt == "Second thing")
        #expect(turn.isLatest)
        #expect(diff.files.map(\.path) == ["Sources/B.swift"])
        #expect(diff.files[0].additions == 1)
        #expect(diff.files[0].deletions == 1)
        #expect(diff.lines.map(\.kind) == [.hunk, .context, .removed, .added])
        #expect(diff.lines[2].oldNumber == 4)
    }

    @Test func anEarlierTurnIsFoundByItsPrompt() throws {
        let path = try transcript([prompt("p1", "First")] + edit("e1", path: "/repo/A.swift") + [prompt("p2", "Second")])
        defer { try? FileManager.default.removeItem(atPath: path) }
        guard case .turn(let turn, let diff) = TurnReview.load(path: path, turnID: "p1", root: "/repo") else {
            Issue.record("No turn read")
            return
        }
        #expect(!turn.isLatest)
        #expect(diff.files.map(\.path) == ["A.swift"])
        #expect(TurnReview.load(path: path, turnID: "gone", root: "/repo") == .turnGone)
    }

    @Test func aLatestTurnWithNoEditsIsStillATurn() throws {
        let path = try transcript([prompt("p1", "Just a question")])
        defer { try? FileManager.default.removeItem(atPath: path) }
        guard case .turn(let turn, let diff) = TurnReview.load(path: path, turnID: nil, root: "/repo") else {
            Issue.record("No turn read")
            return
        }
        #expect(turn.files.isEmpty)
        #expect(diff.files.isEmpty)
    }

    @Test func noTranscriptMeansNoConversation() throws {
        #expect(TurnReview.load(path: nil, turnID: nil, root: "/repo") == .noConversation)
        #expect(TurnReview.load(path: "/nowhere/at/all.jsonl", turnID: nil, root: "/repo") == .noConversation)
        let empty = try transcript([])
        defer { try? FileManager.default.removeItem(atPath: empty) }
        #expect(TurnReview.load(path: empty, turnID: nil, root: "/repo") == .noConversation)
    }

    @Test func reviewTabsSavedBeforeTurnsStillOpen() throws {
        let old = try JSONDecoder().decode(ReviewTarget.self, from: Data(#"{"commit":"abc123","title":"Fix it"}"#.utf8))
        #expect(old.commit == "abc123")
        #expect(old.turn == nil)
        let tab = UUID()
        let saved = try JSONDecoder().decode(ReviewTarget.self, from: JSONEncoder().encode(ReviewTarget.turn("p1", inTab: tab)))
        #expect(saved.turn == ReviewTarget.Turn(tabID: tab, turnID: "p1"))
        #expect(ReviewTarget.turn(nil, inTab: tab).title == "Latest Turn")
        #expect(ReviewTarget.turn(nil, inTab: tab) != ReviewTarget.turn("p1", inTab: tab))
    }
}
