import Foundation
import Testing
@testable import BenchKit

/// The one vocabulary for tool calls, whichever agent made them.
struct ToolKindTests {
    @Test func everyNameLeadsBackToItsKind() {
        for kind in ToolKind.allCases {
            #expect(!kind.names.isEmpty)
            #expect(kind.name == kind.names[0])
            for name in kind.names { #expect(ToolKind(name: name) == kind) }
        }
    }

    @Test func noNameBelongsToTwoKinds() {
        let names = ToolKind.allCases.flatMap(\.names)
        #expect(Set(names).count == names.count)
    }

    @Test func aToolWithNoKindOfItsOwnHasNone() {
        #expect(ToolKind(name: nil) == nil)
        #expect(ToolKind(name: "mcp__linear__create_issue") == nil)
        #expect(ToolKind(name: "bash") == nil)
    }

    @Test func aMessageSaysWhatKindOfCallItIs() {
        let run = TranscriptMessage(id: "1", role: .tool, text: "Running the tests", toolName: "Bash")
        #expect(run.tool == .shell)
        #expect(TranscriptMessage(id: "2", role: .tool, text: "Editing", toolName: "MultiEdit").tool == .edit)
        #expect(TranscriptMessage(id: "3", role: .assistant, text: "Done.").tool == nil)
    }

    @Test func claudesFormatReadsWhatTheParserReads() throws {
        let line = Data(#"{"type":"assistant","uuid":"u1","timestamp":"2026-11-24T10:00:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Hello"}]}}"#.utf8)
        let direct = TranscriptParser.messages(in: line, options: .init())
        #expect(!direct.isEmpty)
        #expect(ClaudeTranscriptFormat().messages(in: line, options: .init()) == direct)
    }
}
