import BenchKit
import Foundation
import Testing
@testable import Bench

/// The commands Claude Code is run with out of sight. These are compared
/// word for word: a changed flag changes what a background call can do.
@MainActor
struct ClaudeBackgroundTests {
    private let background = ClaudeBackground()
    private let other = ClaudeProfile(id: UUID(), name: "Work", folder: "/tmp/work-claude")

    @Test func aOneOffQuestionGetsNoToolsSettingsOrSavedSession() {
        let command = background.oneShot(instructions: "Write a recap.", model: .small, profile: .main())
        #expect(command.arguments == ["-p", "--model", "haiku", "--no-session-persistence", "--tools", "",
                                      "--strict-mcp-config", "--setting-sources", "", "--system-prompt", "Write a recap.",
                                      "--output-format", "json"])
        #expect(command.environment == ["DISABLE_PROMPT_CACHING": "1"])
    }

    @Test func anotherAccountRunsFromItsOwnFolder() {
        let command = background.oneShot(instructions: "x", model: .small, profile: other)
        #expect(command.environment["CLAUDE_CONFIG_DIR"] == "/tmp/work-claude")
        #expect(background.sideQuestion("why?", sessionID: "abc", model: nil, profile: other).environment == ["CLAUDE_CONFIG_DIR": "/tmp/work-claude"])
    }

    @Test func aSideQuestionForksTheSessionForOneTurnWithoutHooks() {
        let command = background.sideQuestion("why?", sessionID: "abc", model: "claude-opus-5-5", profile: .main())
        #expect(command.arguments == ["-p", "--resume", "abc", "--fork-session", "--no-session-persistence",
                                      "--settings", #"{"disableAllHooks":true}"#, "--permission-mode", "dontAsk", "--max-turns", "1",
                                      "--output-format", "stream-json", "--include-partial-messages", "--verbose",
                                      "--model", "claude-opus-5-5", "why?"])
        #expect(command.environment.isEmpty)
    }

    @Test func aCommandLeavesWorkbenchsOwnVariablesBehind() {
        var environment = ["PATH": "/bin", "BENCH_NOTE": "x", "CLAUDECODE": "1", "HOME": "/Users/me"]
        background.sideQuestion("why?", sessionID: "abc", model: nil, profile: other).apply(to: &environment)
        #expect(environment == ["PATH": "/bin", "HOME": "/Users/me", "CLAUDE_CONFIG_DIR": "/tmp/work-claude"])
    }

    @Test func everyProviderListsItsBackground() {
        #expect(Agents.all.map(\.background.agent) == Agents.allBackgrounds.map(\.agent))
        #expect(Agents.background(Agents.backgroundAgent).program == "claude")
    }
}
