import BenchKit
import Foundation
import Testing
@testable import Bench

/// Which agent a new tab runs.
@MainActor
struct AgentChoiceTests {
    private func defaults() -> UserDefaults {
        let name = "AgentChoiceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func claudeUnlessYouChoseOtherwise() {
        let defaults = defaults()
        let missing: (String) -> Bool = { _ in false }
        #expect(Agents.standardID(defaults: defaults, installed: missing) == .claude)
        defaults.set("codex", forKey: Agents.defaultAgentKey)
        // Chosen, but not offered: still Claude.
        #expect(Agents.standardID(defaults: defaults, installed: missing) == .claude)
        #expect(Agents.standardID(defaults: defaults, installed: { _ in true }) == .codex)
        defaults.set(true, forKey: Agents.codexEnabledKey)
        #expect(Agents.standardID(defaults: defaults, installed: missing) == .codex)
        defaults.set("something-newer", forKey: Agents.defaultAgentKey)
        #expect(Agents.standardID(defaults: defaults, installed: missing) == .claude)
    }

    @Test func aMacWithOnlyCodexStartsCodexWithoutBeingTold() {
        let defaults = defaults()
        #expect(Agents.standardID(defaults: defaults, installed: { $0 == "codex" }) == .codex)
        #expect(Agents.standardID(defaults: defaults, installed: { _ in true }) == .claude)
        #expect(Agents.standardID(defaults: defaults, installed: { $0 == "claude" }) == .claude)
    }

    @Test func newTabsRunAnAgentThatsReady() {
        var agents = AgentSetup.all
        agents[0].state = .notInstalled
        agents[1].state = .ready(version: "1.0")
        #expect(AgentSetup.preferred(among: agents, chosen: .claude) == .codex)
        agents[0].state = .ready(version: nil)
        // Your choice stands while it's ready.
        #expect(AgentSetup.preferred(among: agents, chosen: .codex) == .codex)
        #expect(AgentSetup.preferred(among: agents, chosen: .claude) == .claude)
        agents[0].state = .signedOut
        agents[1].state = .notInstalled
        #expect(AgentSetup.preferred(among: agents, chosen: .claude) == .claude)
    }

    @Test func oneAgentIsEnoughForSetup() {
        var codex = AgentSetup.all[1]
        codex.state = .notInstalled
        // Missing with nothing else ready is a problem. Beside a ready agent it's optional.
        if case .missing = SetupCheck.row(for: codex, isOptional: false).0 {} else { Issue.record("should be missing") }
        if case .skipped = SetupCheck.row(for: codex, isOptional: true).0 {} else { Issue.record("should be optional") }
        if case .installAgent(let agent)? = SetupCheck.row(for: codex, isOptional: true).1 { #expect(agent.id == .codex) } else { Issue.record("should offer to install") }
        codex.state = .signedOut
        if case .signInToAgent? = SetupCheck.row(for: codex, isOptional: false).1 {} else { Issue.record("should offer to sign in") }
        codex.state = .ready(version: "0.172.0")
        #expect(SetupCheck.row(for: codex, isOptional: false).0 == .ok("Version 0.172.0"))
        // Claude Code is the one Workbench is built for. Codex is in beta.
        #expect(!AgentSetup.all[0].isBeta && AgentSetup.all[1].isBeta)
        #expect(AgentSetup.all[1].title == "Codex (Beta)")
    }

    @Test func everyAgentSaysHowToInstallAndSignIn() {
        for agent in AgentSetup.all {
            #expect(!agent.installCommand.isEmpty && agent.signInCommand.hasPrefix(agent.program))
            #expect(Agents.provider(agent.id)?.program == agent.program)
        }
        #expect(AgentSetup.all[0].installCommand == "curl -fsSL https://claude.ai/install.sh | bash")
    }

    @Test func aTabKeepsTheAgentItWasMadeWith() throws {
        let tab = TabRecord(kind: .agent, agent: .codex)
        #expect(tab.agent == .codex && tab.title == "Codex")
        let saved = try JSONDecoder().decode(TabRecord.self, from: JSONEncoder().encode(tab))
        #expect(saved.agent == .codex && saved.provider?.id == .codex)
        #expect(TabRecord(kind: .shell, agent: .codex).agent == nil)
    }

    @Test func benchAgentTakesWith() throws {
        let command = try #require(BenchCommand.all.first { $0.name == "agent" })
        #expect(command.valueOptions.contains("with"))
        #expect(command.usage.contains("[--with <agent>]"))
    }

    @Test func aPastCodexSessionIsFoundByItsFile() {
        // A session nobody has is nobody's.
        #expect(SessionHistory.agent(ofSession: "no-such-session", projectPath: "/nowhere") == nil)
    }
}
