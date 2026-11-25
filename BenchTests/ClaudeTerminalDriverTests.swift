import BenchKit
import Foundation
import Testing
@testable import Bench

/// How Claude Code's screen and title are read.
@MainActor
struct ClaudeTerminalDriverTests {
    private let driver = ClaudeTerminalDriver()
    private let rule = String(repeating: "─", count: 40)

    @Test func readsTheMessageBoxBetweenTheLastTwoRules() {
        let screen = "● Done.\n\n\(rule)\n❯ fix the login\n  crash too\n\(rule)\n  ⏵⏵ accept edits on"
        #expect(driver.messageBox(in: screen) == "fix the login\ncrash too")
        #expect(driver.messageBox(in: "\(rule)\n❯ \n\(rule)") == "")
    }

    @Test func noMessageBoxWithoutItsPromptMark() {
        #expect(driver.messageBox(in: "\(rule)\nsomething else\n\(rule)") == nil)
        #expect(driver.messageBox(in: "no rules here") == nil)
        #expect(driver.messageBox(in: nil) == nil)
    }

    @Test func tellsItsOwnHintsFromTypedWords() {
        #expect(driver.isHint("Press up to edit queued messages"))
        #expect(driver.isQueueHint("Press up to edit queued messages"))
        #expect(!driver.isQueueHint("Press Ctrl-C again to exit"))
        #expect(!driver.isHint("fix the login crash"))
    }

    @Test func readsTheFolderFromTheTrustPrompt() {
        let screen = """
            Accessing workspace:

            /Users/me/Apps/
            Recipes

            ❯ 1. No, exit
              2. Yes, I trust this folder

            Enter to confirm · Esc to cancel
            """
        #expect(driver.trustFolder(in: screen) == "/Users/me/Apps/Recipes")
        let prompt = driver.startupPrompt(in: screen)
        #expect(prompt?.question.question == "Do you trust the files in /Users/me/Apps/Recipes?")
        #expect(prompt?.question.options.map(\.label) == ["Yes, I trust this folder", "No, exit"])
        // The cursor starts on "No, exit": yes moves down first, and is checked.
        #expect(prompt?.answers[0].moves == [.downArrow])
        #expect(prompt?.answers[1].moves == [])
        #expect(!StartupPrompt.cursorIsOn("Yes, I trust this folder", in: screen))
        #expect(StartupPrompt.cursorIsOn("Yes, I trust this folder", in: "  1. No, exit\n❯ 2. Yes, I trust this folder"))
    }

    @Test func aTrustPromptLeftOnScreenAfterQuittingIsNotAsking() {
        #expect(driver.startupPrompt(in: "Yes, I trust this folder\nNo, exit\n\nme@mac ~ %") == nil)
        #expect(driver.startupPrompt(in: "❯ hello") == nil)
    }

    @Test func readsThePlanPickersChoices() {
        let screen = """
            Would you like to proceed?

            ❯ 1. Yes, and auto-accept edits (shift+tab)
              2. Yes, and manually approve edits
              3. Type here to tell Claude what to change
            """
        let plan = driver.planApproval(in: screen)
        #expect(plan?.options.map(\.label) == ["Yes, and auto-accept edits", "Yes, and manually approve edits"])
        #expect(plan?.allowsOther == true)
        #expect(driver.planApproval(in: "Would you like to proceed?\n  1. Yes\n  2. No") == nil)
    }

    @Test func knowsItsOwnTitles() {
        #expect(driver.titleIsAgents("✳ Fix the login crash"))
        #expect(driver.titleIsAgents("Claude Code"))
        #expect(driver.titleIsAgents(nil))
        #expect(!driver.titleIsAgents("me@mac:~/Apps"))
        #expect(driver.titleIsStarting("claude --settings x"))
        #expect(!driver.titleIsStarting("zsh"))
        #expect(driver.isWorkingMark("⠋".unicodeScalars.first!))
        #expect(driver.isWorkingMark("◐".unicodeScalars.first!))
        #expect(!driver.isWorkingMark("✳".unicodeScalars.first!))
    }
}
