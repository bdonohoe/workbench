import BenchKit
import Foundation
import Testing
@testable import Bench

/// Which agent's reader a session file gets.
@MainActor
struct AgentTranscriptsTests {
    @Test func aFileUnderClaudesProjectsFolderIsClaudes() {
        let file = ClaudeProfile.main().projectsURL.appendingPathComponent("-Users-me-App/abc.jsonl").path
        #expect(ClaudeTranscripts().owns(file))
        #expect(Agents.transcripts(for: file).agent == .claude)
    }

    @Test func aFileNobodyClaimsIsReadAsClaudes() {
        #expect(!ClaudeTranscripts().owns("/tmp/somewhere/else.jsonl"))
        #expect(Agents.transcripts(for: "/tmp/somewhere/else.jsonl").agent == .claude)
    }

    @Test func everyProviderListsItsReader() {
        #expect(Agents.all.map(\.transcripts.agent) == Agents.knownTranscripts.map(\.agent))
        #expect(Agents.all.map(\.id) == Agents.knownTranscripts.map(\.agent))
    }

    @Test func claudeKeepsAProjectsSessionsInAFolderNamedForItsPath() {
        let folder = ClaudeTranscripts.folder(forProject: "/Users/me/My App.swift", account: .main())
        #expect(folder.lastPathComponent == "-Users-me-My-App-swift")
        #expect(folder.deletingLastPathComponent() == ClaudeProfile.main().projectsURL)
    }
}
