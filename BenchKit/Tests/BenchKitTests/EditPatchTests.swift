import Foundation
import Testing
@testable import BenchKit

/// What an edit changed, read from the result Claude Code saves for it.
@Suite struct EditPatchTests {
    private let keeping = TranscriptParser.Options(keepsResults: true, keepsPatches: true)

    private func line(result: Any?, isError: Bool = false) -> Data {
        var entry: [String: Any] = [
            "type": "user", "uuid": "r1", "timestamp": "2026-11-21T10:00:00.000Z",
            "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "call-1", "content": "done", "is_error": isError]]],
        ]
        if let result { entry["toolUseResult"] = result }
        return try! JSONSerialization.data(withJSONObject: entry)
    }

    private let edit: [String: Any] = [
        "filePath": "/repo/Sources/../Sources/App.swift", "oldString": "b", "newString": "B\nC",
        "structuredPatch": [["oldStart": 4, "oldLines": 3, "newStart": 4, "newLines": 4, "lines": [" a", "-b", "+B", "+C", " d"]]],
    ]

    @Test func anEditKeepsItsHunksAndCounts() {
        let messages = TranscriptParser.messages(in: line(result: edit), options: keeping)
        let patch = messages.first?.patch
        #expect(messages.first?.resultOf == "call-1")
        #expect(patch?.path == "/repo/Sources/App.swift")
        #expect(patch?.isNewFile == false)
        #expect(patch?.additions == 2)
        #expect(patch?.deletions == 1)
        #expect(patch?.hunks == [EditPatch.Hunk(oldStart: 4, newStart: 4, lines: [" a", "-b", "+B", "+C", " d"])])
        #expect(patch?.truncated == false)
    }

    @Test func aNewFileIsAllAdditions() {
        let created: [String: Any] = ["type": "create", "filePath": "/repo/New.swift", "content": "one\ntwo\n", "structuredPatch": [[String: Any]]()]
        let patch = TranscriptParser.messages(in: line(result: created), options: keeping).first?.patch
        #expect(patch?.isNewFile == true)
        #expect(patch?.additions == 2)
        #expect(patch?.deletions == 0)
        #expect(patch?.hunks == [EditPatch.Hunk(oldStart: 0, newStart: 1, lines: ["+one", "+two"])])
    }

    @Test func aFileWrittenOverKeepsItsPatch() {
        let updated: [String: Any] = ["type": "update", "filePath": "/repo/Old.swift", "content": "new",
                                      "structuredPatch": [["oldStart": 1, "newStart": 1, "lines": ["-old", "+new"]]]]
        let patch = TranscriptParser.messages(in: line(result: updated), options: keeping).first?.patch
        #expect(patch?.isNewFile == false)
        #expect(patch?.additions == 1)
        #expect(patch?.deletions == 1)
    }

    @Test func readersThatDidNotAskGetNone() {
        let messages = TranscriptParser.messages(in: line(result: edit), options: .init(keepsResults: true))
        #expect(messages.count == 1)
        #expect(messages.first?.patch == nil)
    }

    @Test func aFailedEditHasNone() {
        #expect(TranscriptParser.messages(in: line(result: "Error: String to replace not found", isError: true), options: keeping).first?.patch == nil)
        #expect(TranscriptParser.messages(in: line(result: edit, isError: true), options: keeping).first?.patch == nil)
    }

    @Test func otherResultsHaveNone() {
        let ran: [String: Any] = ["stdout": "ok", "stderr": "", "interrupted": false]
        #expect(TranscriptParser.messages(in: line(result: ran), options: keeping).first?.patch == nil)
        #expect(TranscriptParser.messages(in: line(result: nil), options: keeping).first?.patch == nil)
    }

    @Test func aVeryLongChangeIsCutButCounted() {
        let content = (0..<(EditPatch.keptLines + 500)).map { "line \($0)" }.joined(separator: "\n")
        let created: [String: Any] = ["type": "create", "filePath": "/repo/Big.txt", "content": content, "structuredPatch": [[String: Any]]()]
        let patch = TranscriptParser.messages(in: line(result: created), options: keeping).first?.patch
        #expect(patch?.additions == EditPatch.keptLines + 500)
        #expect(patch?.hunks.first?.lines.count == EditPatch.keptLines)
        #expect(patch?.truncated == true)
    }

    @Test func aPatchSurvivesCodingAndOldMessagesStillDecode() throws {
        let message = TranscriptParser.messages(in: line(result: edit), options: keeping)[0]
        let decoded = try JSONDecoder().decode(TranscriptMessage.self, from: JSONEncoder().encode(message))
        #expect(decoded.patch == message.patch)
        let old = try JSONDecoder().decode(TranscriptMessage.self, from: Data(#"{"id":"a","role":"tool","text":"x"}"#.utf8))
        #expect(old.patch == nil)
    }
}
