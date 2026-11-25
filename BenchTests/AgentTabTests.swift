import BenchKit
import Foundation
import Testing
@testable import Bench

/// How a tab's agent is saved. A Claude tab must stay exactly as it was
/// before tabs knew about agents, in both directions, and a tab for an
/// agent this version doesn't have must drop out on its own.
@MainActor
struct AgentTabTests {
    private func saved(_ tab: TabRecord) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(tab)) as? [String: Any])
    }

    private func read(_ json: String) throws -> TabRecord {
        try JSONDecoder().decode(TabRecord.self, from: Data(json.utf8))
    }

    @Test func aClaudeTabIsSavedAsItAlwaysWas() throws {
        let tab = TabRecord(kind: .agent, initialPrompt: "Fix it")
        #expect(tab.agent == .claude)
        #expect(tab.title == "Claude")
        let json = try saved(tab)
        #expect(json["kind"] as? String == "claude")
        #expect(json["agent"] == nil)
        #expect(Set(json.keys) == ["id", "kind", "title", "initialPrompt"])
    }

    @Test func aTabSavedBeforeAgentsIsAClaudeTab() throws {
        let tab = try read(#"{"id":"\#(UUID().uuidString)","kind":"claude","title":"Claude","showsChat":true}"#)
        #expect(tab.kind == .agent)
        #expect(tab.agent == .claude)
        #expect(tab.provider?.id == .claude)
        #expect(tab.showsChat == true)
    }

    @Test func otherKindsHaveNoAgent() throws {
        #expect(TabRecord(kind: .shell).agent == nil)
        #expect(TabRecord(kind: .shell, command: "bun run dev").title == "bun run dev")
        let tab = try read(#"{"id":"\#(UUID().uuidString)","kind":"shell","title":"zsh"}"#)
        #expect(tab.agent == nil)
        #expect(try saved(tab)["agent"] == nil)
    }

    @Test func aTabForAnAgentThisVersionLacksIsLeftOut() throws {
        #expect(throws: DecodingError.self) {
            try read(#"{"id":"\#(UUID().uuidString)","kind":"agent","agent":"hologram","title":"From the future"}"#)
        }
        #expect(throws: DecodingError.self) {
            try read(#"{"id":"\#(UUID().uuidString)","kind":"agent","title":"No agent named"}"#)
        }
    }

    @Test func everySavedFieldComesBack() throws {
        var tab = TabRecord(kind: .agent, initialPrompt: "Hello")
        tab.resumeSessionID = "abc"
        tab.showsChat = true
        tab.claudeAccountID = UUID()
        tab.customTitle = "Mine"
        let back = try JSONDecoder().decode(TabRecord.self, from: JSONEncoder().encode(tab))
        #expect(back == tab)
        var file = TabRecord(filePath: "Sources/App.swift")
        file.customTitle = "App"
        #expect(try JSONDecoder().decode(TabRecord.self, from: JSONEncoder().encode(file)) == file)
        var page = TabRecord(previewURL: URL(string: "http://localhost:3000")!)
        page.pageURL = URL(string: "http://localhost:3000/about")
        #expect(try JSONDecoder().decode(TabRecord.self, from: JSONEncoder().encode(page)) == page)
    }
}
