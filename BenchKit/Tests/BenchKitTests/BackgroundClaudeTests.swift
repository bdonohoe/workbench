import Testing
@testable import BenchKit

@Test func readsAResultWithItsUsage() throws {
    let output = #"{"type":"result","is_error":false,"result":"  Fixed it.\n","usage":{"input_tokens":1118,"output_tokens":54},"modelUsage":{"claude-haiku-5-5":{"inputTokens":1118}}}"#
    let reply = try #require(BackgroundReply.parse(output))
    #expect(reply.text == "Fixed it.")
    #expect(!reply.isError)
    #expect(reply.model == "claude-haiku-5-5")
    #expect(reply.usage?["input_tokens"] as? Int == 1118)
}

@Test func notesAFailedResult() throws {
    let reply = try #require(BackgroundReply.parse(#"{"type":"result","is_error":true,"result":"Not logged in"}"#))
    #expect(reply.isError)
    #expect(reply.model == nil)
    #expect(reply.usage == nil)
}

@Test func plainTextIsNotAResult() {
    #expect(BackgroundReply.parse("Fixed it.") == nil)
    #expect(BackgroundReply.parse(#"{"tasks":[]}"#) == nil)
}

private let folders = ["/Users/me/.claude/projects", "/Users/me/.claude-work/projects"]

@Test func findsTheAccountByTranscriptFolder() {
    #expect(TranscriptOwner.index(of: "/Users/me/.claude/projects/-a/1.jsonl", amongProjectFolders: folders) == 0)
    #expect(TranscriptOwner.index(of: "/Users/me/.claude-work/projects/-a/1.jsonl", amongProjectFolders: folders) == 1)
}

@Test func aSimilarFolderNameIsNotAMatch() {
    #expect(TranscriptOwner.index(of: "/Users/me/.claude/projects-old/1.jsonl", amongProjectFolders: folders) == nil)
    #expect(TranscriptOwner.index(of: "/tmp/1.jsonl", amongProjectFolders: folders) == nil)
}

@Test func theDeepestFolderWins() {
    let nested = ["/a/projects", "/a/projects/inner/projects"]
    #expect(TranscriptOwner.index(of: "/a/projects/inner/projects/1.jsonl", amongProjectFolders: nested) == 1)
    #expect(TranscriptOwner.index(of: "/a/projects/2.jsonl", amongProjectFolders: nested) == 0)
}
