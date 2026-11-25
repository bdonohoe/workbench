import Foundation
import Testing
@testable import BenchKit

struct AgentCatalogTests {
    private func session(_ json: String) throws -> CompanionSession {
        try CompanionCoding.decoder.decode(CompanionSession.self, from: Data(json.utf8))
    }

    @Test func aSessionThatDoesntSayIsClaudes() throws {
        let old = try session(#"{"id":"6F1C2B5E-0000-4000-8000-000000000001","title":"Recipes","activity":"idle","isAllowOrDeny":false}"#)
        #expect(old.agent == nil)
        #expect(old.agentTitle == "Claude")
        #expect(old.agentCatalog == .claude)
        #expect(old.agentCatalog.models == ModelChoice.all)
        #expect(old.agentCatalog.has(.questionCards))
    }

    @Test func aClaudeSessionIsSentWithoutTheNewFields() throws {
        let sent = CompanionSession(id: UUID(), title: "Recipes", activity: .idle)
        let json = String(decoding: try CompanionCoding.encoder.encode(sent), as: UTF8.self)
        #expect(!json.contains("agent"))
        #expect(!json.contains("catalog"))
    }

    @Test func anotherAgentsCatalogSurvivesTheTrip() throws {
        var sent = CompanionSession(id: UUID(), title: "Recipes", activity: .idle)
        sent.agent = AgentID("codex")
        sent.agentName = "Codex"
        sent.catalog = AgentCatalog(models: [ModelChoice(alias: "gpt", name: "GPT")], efforts: [], quickCommands: [.compact],
                                    features: [.pictures, .sideQuestions])
        let back = try CompanionCoding.decoder.decode(CompanionSession.self, from: CompanionCoding.encoder.encode(sent))
        #expect(back.agent == AgentID("codex"))
        #expect(back.agentTitle == "Codex")
        #expect(back.agentCatalog == sent.catalog)
        #expect(!back.agentCatalog.has(.questionCards))
        #expect(back.agentCatalog.efforts.isEmpty)
    }

    @Test func aCatalogFromANewerMacDropsWhatThisVersionDoesntKnow() throws {
        let json = #"{"models":[{"alias":"gpt","name":"GPT","summary":""}],"efforts":["high","galactic"],"quickCommands":["compact","teleport"],"features":["pictures","mindReading"]}"#
        let catalog = try CompanionCoding.decoder.decode(AgentCatalog.self, from: Data(json.utf8))
        #expect(catalog.efforts == [.high])
        #expect(catalog.quickCommands == [.compact])
        #expect(catalog.features == [.pictures])
    }
}
