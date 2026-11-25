import BenchKit
import Foundation
import Testing
@testable import Bench

/// Codex run out of sight. The outputs here are what Codex 0.172 printed.
@MainActor
struct CodexBackgroundTests {
    private let background = CodexBackground()

    private static let oneShot = """
        {"type":"thread.started","thread_id":"01a20eb0-1ab4-7771-9ad4-19986dd4288c"}
        {"type":"turn.started"}
        {"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"Fixed the login crash in `Login.swift` and ran the tests; they passed."}}
        {"type":"turn.completed","usage":{"input_tokens":18920,"cached_input_tokens":11648,"cache_write_input_tokens":0,"output_tokens":21,"reasoning_output_tokens":0}}
        """

    @Test func aOneOffQuestionReadsNothingOfYoursAndSavesNothing() {
        let command = background.oneShot(instructions: "Say \"hi\"", model: .small, profile: .main(named: "Main"))
        #expect(command.arguments.starts(with: ["exec", "--ephemeral", "--ignore-user-config", "--skip-git-repo-check", "-s", "read-only", "--json"]))
        #expect(command.arguments.last == "-")
        #expect(command.arguments.contains(#"developer_instructions="Say \"hi\"""#))
    }

    @Test func readsAOneOffReply() throws {
        let reply = try #require(background.oneShotReply(in: Self.oneShot))
        #expect(reply.text == "Fixed the login crash in `Login.swift` and ran the tests; they passed.")
        #expect(!reply.isError)
        let tally = background.tally(usage: try #require(reply.usage), model: "gpt-6-luna")
        // Codex counts cached tokens inside its input tokens.
        #expect(tally.input == 7272 && tally.cacheRead == 11648 && tally.output == 21 && tally.cost == 0)
    }

    @Test func aFailedOrForeignReplyIsNotAnAnswer() {
        #expect(background.oneShotReply(in: "zsh: command not found: codex") == nil)
        #expect(background.oneShotReply(in: #"{"type":"thread.started","thread_id":"x"}"# + "\n" + #"{"type":"turn.failed","error":{"message":"no"}}"#)?.isError == true)
    }

    @Test func aSideQuestionForksTheSessionReadOnly() {
        let command = background.sideQuestion("what changed?", sessionID: "abc", model: "gpt-6-luna", profile: .main(named: "Main"))
        #expect(command.arguments == ["exec", "fork", "abc", "--ephemeral", "--json", "-c", #"sandbox_mode="read-only""#, "-m", "gpt-6-luna", "what changed?"])
    }

    @Test func readsASideQuestionsAnswer() {
        let lines = Self.oneShot.components(separatedBy: "\n")
        #expect(background.sideQuestionEvent(in: lines[0]) == nil)
        #expect(background.sideQuestionEvent(in: lines[2]) == .text("Fixed the login crash in `Login.swift` and ran the tests; they passed."))
        #expect(background.sideQuestionEvent(in: lines[3]) == .finished(text: "", isError: false))
        let call = #"{"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"/bin/zsh -lc ls","aggregated_output":"","exit_code":null,"status":"in_progress"}}"#
        #expect(background.startsToolCall(call))
        #expect(!background.startsToolCall(lines[2]))
    }

    @Test func readsWhoIsSignedIn() {
        let plan = CodexBackground.status(from: "Logged in using ChatGPT\n", plan: "pro")
        #expect(plan?.loggedIn == true && plan?.billing == .plan && plan?.summary == "Pro plan")
        #expect(CodexBackground.status(from: "Logged in using ChatGPT", plan: nil)?.summary == "ChatGPT plan")
        #expect(CodexBackground.status(from: "Logged in using an API key - sk-...abc", plan: nil)?.billing == .perToken)
        #expect(CodexBackground.status(from: "Not logged in", plan: nil)?.loggedIn == false)
        #expect(CodexBackground.status(from: "zsh: command not found", plan: nil) == nil)
    }

    @Test func readsPlanLimitsFromASession() {
        let limits = CodexPlanLimits.limits(from: [
            "primary": ["used_percent": 12.0, "window_minutes": 300, "resets_at": 1_795_000_000],
            "secondary": ["used_percent": 40.5, "window_minutes": 10080, "resets_at": 1_795_500_000],
            "plan_type": "pro",
        ])
        #expect(limits.map(\.id) == ["five_hour", "seven_day"])
        #expect(limits.map(\.shortName) == ["5h", "Week"])
        #expect(limits[0].percent == 12 && limits[0].window == 5 * 3600)
        #expect(limits[1].resetsAt == Date(timeIntervalSince1970: 1_795_500_000))
        #expect(CodexPlanLimits.limits(from: [:]).isEmpty)
    }

    @Test func listsTheModelsCodexShowsInItsPicker() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Screens/codex/models.json")
        let models = CodexModelList.parse(try String(contentsOf: file, encoding: .utf8))
        #expect(models.first == ModelChoice(alias: "gpt-6.2-sol", name: "GPT-6.2 Sol", summary: "Fast, go-to model for coding and everyday work"))
        // Hidden ones, like the review model, are left out.
        #expect(!models.contains { $0.alias == "codex-auto-review" || $0.alias == "gpt-reserve" })
        #expect(models.contains { $0.alias == "gpt-6-luna" })
        // A session's model, as the reader names it, finds its row.
        #expect(models.first { $0.matches(CodexModels.name("gpt-6-luna")) }?.alias == "gpt-6-luna")
        #expect(models[0].command == "/model gpt-6.2-sol")
        #expect(CodexModelList.parse("nope").isEmpty)
    }

    @Test func effortIsSetThroughTheModelCommand() {
        let driver = CodexTerminalDriver()
        #expect(driver.typed("/effort high") == "/model --reasoning=high")
        #expect(driver.typed("fix the /effort high bug") == "fix the /effort high bug")
        #expect(ClaudeTerminalDriver().typed("/effort high") == "/effort high")
        #expect(driver.returnDelay > ClaudeTerminalDriver().returnDelay)
    }

    @Test func readsTheEffortCodexStartsWith() {
        #expect(CodexCatalog.savedEffort(in: "model = \"gpt-6.2-sol\"\nmodel_reasoning_effort = \"medium\"\n\n[projects.x]\n") == "medium")
        #expect(CodexCatalog.savedEffort(in: "[profiles.a]\nmodel_reasoning_effort = \"high\"\n") == nil)
        #expect(CodexCatalog.savedEffort(in: "") == nil)
    }
}
