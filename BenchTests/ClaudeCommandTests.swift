import Foundation
import Testing
@testable import Bench

/// Settings > Claude > Command: what a new Claude tab types in place of `claude`.
struct ClaudeCommandTests {
    private func defaults(_ value: String?) -> UserDefaults {
        let store = UserDefaults(suiteName: "ClaudeCommandTests-\(UUID().uuidString)")!
        store.set(value, forKey: Agents.claude.commandKey)
        return store
    }

    @Test func emptyMeansPlainClaude() {
        #expect(Agents.claude.command(defaults(nil)) == "claude")
        #expect(Agents.claude.command(defaults("   ")) == "claude")
    }

    @Test func theUsersCommandIsKept() {
        #expect(Agents.claude.command(defaults(" claude --permission-mode acceptEdits ")) == "claude --permission-mode acceptEdits")
        #expect(Agents.claude.command(defaults("~/bin/my-claude")) == "~/bin/my-claude")
    }

    @Test func lineBreaksCantRunItEarly() {
        #expect(Agents.claude.command(defaults("claude\n--permission-mode plan\n")) == "claude --permission-mode plan")
    }
}

/// The warnings under Settings > Claude > Command.
struct ClaudeCommandCheckTests {
    private func warnings(_ command: String, known: Set<String> = ["claude", "/usr/local/bin/my-claude"]) -> [String] {
        ClaudeCommandCheck.warnings(for: command) { known.contains($0) }
    }

    @Test func goodCommandsHaveNoWarnings() {
        #expect(warnings("").isEmpty)
        #expect(warnings("claude").isEmpty)
        #expect(warnings("claude --permission-mode acceptEdits").isEmpty)
        #expect(warnings("FOO=1 claude --model 'opus'").isEmpty)
        #expect(warnings("/usr/local/bin/my-claude --verbose").isEmpty)
        #expect(warnings(#"claude --append-system-prompt "be #1; brief""#).isEmpty)
    }

    @Test func aMissingProgramIsNamed() {
        let found = warnings("claud --permission-mode plan")
        #expect(found.count == 1)
        #expect(found[0].contains("claud "))
    }

    @Test func openQuotesAndTrailingBackslashWarn() {
        #expect(warnings("claude --model 'opus").first?.contains("single quote") == true)
        #expect(warnings(#"claude --model "opus"#).first?.contains("double quote") == true)
        #expect(warnings(#"claude \"#).first?.contains(#"ends with \"#) == true)
    }

    @Test func commentsAndOperatorsWarn() {
        #expect(warnings("claude # mine").contains { $0.contains("#") })
        #expect(warnings("claude; echo hi").contains { $0.contains(" ; ") || $0.contains("with ;") })
        #expect(warnings("cd /tmp && claude").contains { $0.contains("&&") })
        #expect(warnings("claude | tee log").contains { $0.contains("|") })
        // A # inside a word isn't a comment.
        #expect(warnings("claude --name a#b").isEmpty)
    }

    @Test func optionsWorkbenchManagesWarn() {
        #expect(warnings("claude -p").contains { $0.contains("-p") })
        #expect(warnings("claude --continue").contains { $0.contains("--continue") })
        #expect(warnings("claude --resume=abc").contains { $0.contains("--resume") })
    }
}
