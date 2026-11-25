import Foundation
import Testing
@testable import BenchKit

@Suite struct SideQuestionTests {
    @Test func readsTheQuestion() {
        #expect(SideQuestion.question(in: "/btw what does this do?") == "what does this do?")
        #expect(SideQuestion.question(in: "  /BTW  why\nthat one? ") == "why\nthat one?")
        #expect(SideQuestion.question(in: "/btw") == "")
    }

    @Test func leavesOtherMessagesAlone() {
        #expect(SideQuestion.question(in: "btw what does this do?") == nil)
        #expect(SideQuestion.question(in: "/btwx something") == nil)
        #expect(SideQuestion.question(in: "/compact") == nil)
        #expect(SideQuestion.question(in: "say /btw later") == nil)
    }

    @Test func promptEndsWithTheQuestion() {
        let prompt = SideQuestion.prompt(for: "Is it Tuesday?")
        #expect(prompt.hasPrefix("<system-reminder>"))
        #expect(prompt.hasSuffix("\nIs it Tuesday?"))
        #expect(SideQuestion.prompt(for: "Why?", running: "npm test").contains("on this step: npm test."))
    }

    @Test func decodesWhatAnOlderMacLeavesOut() throws {
        let id = UUID()
        let decoded = try JSONDecoder().decode(SideQuestion.self, from: Data(#"{"id":"\#(id.uuidString)","state":"later"}"#.utf8))
        #expect(decoded == SideQuestion(id: id, question: "", answer: "", state: .answered))
    }

    @Test func streamsText() {
        let line = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"One, two"}}}"#
        #expect(SideQuestionStream.event(in: line) == .text("One, two"))
    }

    @Test func skipsOtherEvents() {
        #expect(SideQuestionStream.event(in: #"{"type":"system","subtype":"init"}"#) == nil)
        #expect(SideQuestionStream.event(in: #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta","partial_json":"{"}}}"#) == nil)
        #expect(SideQuestionStream.event(in: "not json") == nil)
    }

    @Test func noticesAToolCallAsItStarts() {
        let start = #"{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"Bash","input":{}}}}"#
        #expect(SideQuestionStream.event(in: start) == .toolCall)
        #expect(SideQuestionStream.startsToolCall(start))
        let whole = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Sure."},{"type":"tool_use","id":"toolu_1","name":"mcp__mail__send","input":{}}]}}"#
        #expect(SideQuestionStream.startsToolCall(whole))
        // Text that only talks about tools is still text.
        let text = #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}"#
        #expect(!SideQuestionStream.startsToolCall(text))
        let talk = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"a tool_use block"}}}"#
        #expect(!SideQuestionStream.startsToolCall(talk))
        #expect(SideQuestionStream.event(in: talk) == .text("a tool_use block"))
        #expect(!SideQuestionStream.startsToolCall(#"{"type":"assistant","message":{"content":[{"type":"text","text":"tool_use"}]}}"#))
    }

    @Test func finishes() {
        #expect(SideQuestionStream.event(in: #"{"type":"result","subtype":"success","is_error":false,"result":" Five. "}"#)
                == .finished(text: "Five.", isError: false))
        #expect(SideQuestionStream.event(in: #"{"type":"result","subtype":"error_max_turns"}"#)
                == .finished(text: "", isError: true))
    }

    @Test func findsTheSessionFolder() {
        let text = """
        {"type":"mode","mode":"normal"}
        {"type":"user","cwd":"/Users/me/Code/App","message":{"content":"hi"}}
        {"type":"user","cwd":"/elsewhere"}
        """
        #expect(TranscriptFolder.find(in: text) == "/Users/me/Code/App")
        #expect(TranscriptFolder.find(in: #"{"type":"mode"}"#) == nil)
    }
}
