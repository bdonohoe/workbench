import BenchKit
import Foundation
import Testing
@testable import Bench

/// How Codex's screens are read. The screens are real ones, captured from
/// Codex 0.172 in a terminal 110 columns wide (`Screens/codex`).
@MainActor
struct CodexTerminalDriverTests {
    private let driver = CodexTerminalDriver()

    private func screen(_ name: String) throws -> String {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Screens/codex")
        return try String(contentsOf: folder.appendingPathComponent("\(name).txt"), encoding: .utf8)
    }

    @Test func anEmptyMessageBoxReadsAsEmptyNotAsItsHint() throws {
        #expect(driver.messageBox(in: try screen("composer-empty")) == "")
        #expect(driver.showsMessageBox(in: try screen("composer-empty")))
        #expect(driver.isHint("Ask Codex to do anything"))
    }

    @Test func readsWhatsTypedInTheMessageBox() throws {
        #expect(driver.messageBox(in: try screen("composer-typed")) == "hello there")
    }

    @Test func theMessageBoxIsStillThereWhileCodexWorks() throws {
        // Your earlier messages start with the same mark; the box is the last.
        #expect(driver.messageBox(in: try screen("working-queued")) == "")
        #expect(driver.messageBox(in: try screen("interrupted")) == "")
    }

    @Test func noMessageBoxWhileItAsksOrAfterItQuits() throws {
        #expect(!driver.showsMessageBox(in: try screen("approval")))
        #expect(!driver.showsMessageBox(in: try screen("trust")))
        #expect(!driver.showsMessageBox(in: try screen("hooks-review")))
        let quit = """
            › Ask Codex to do anything
              GPT-6.2-Sol medium · ~/Apps/Recipes
            Token usage: total=9,157 input=9,061 (+ 35,840 cached) output=96
            To continue this session, run:
            codex resume 01a20e9e-7a2b-7452-b323-747be760c50d
            me@mac Recipes %
            """
        #expect(!driver.showsMessageBox(in: quit))
        #expect(!driver.showsMessageBox(in: nil))
    }

    @Test func readsTheFolderTrustPrompt() throws {
        let prompt = try #require(driver.startupPrompt(in: try screen("trust")))
        #expect(prompt.question.question == "Do you trust the files in ~/Apps/Bench/build/codex-fixtures/untrusted?"
            || prompt.question.question == "Do you trust the files in /Users/matt/Apps/Bench/build/codex-fixtures/untrusted?")
        #expect(prompt.question.options.map(\.label) == ["Trust and continue", "Go back"])
        // The cursor starts on "Trust and continue".
        #expect(prompt.answers[0].moves.isEmpty)
        #expect(prompt.answers[1].moves == [.downArrow])
        #expect(prompt.blocker == "is asking whether to trust this folder")
    }

    @Test func readsTheHookReviewPrompt() throws {
        let prompt = try #require(driver.startupPrompt(in: try screen("hooks-review")))
        #expect(prompt.question.options.map(\.label) == ["Trust all and continue", "Continue without trusting"])
        #expect(prompt.answers[0].moves == [.downArrow])
        #expect(prompt.answers[0].picked == "Trust all and continue")
        #expect(prompt.answers[1].moves == [.downArrow, .downArrow])
        #expect(!StartupPrompt.cursorIsOn("Trust all and continue", in: try screen("hooks-review")))
        #expect(StartupPrompt.cursorIsOn("Review hooks", in: try screen("hooks-review")))
    }

    @Test func noStartupPromptOnceCodexIsUp() throws {
        for name in ["composer-empty", "composer-typed", "approval", "working-queued"] {
            #expect(driver.startupPrompt(in: try screen(name)) == nil, "\(name)")
        }
    }

    @Test func knowsItsTitlesAndKeys() {
        #expect(driver.isWorkingMark("⠋".unicodeScalars.first!))
        #expect(!driver.isWorkingMark("[".unicodeScalars.first!))
        #expect(driver.titleIsStarting("codex -c x"))
        #expect(driver.allowKey == .returnKey && driver.denyKey == .escape && driver.interruptKey == .escape)
        #expect(driver.sendQueueNowKey == nil && driver.nextModeKey == nil && !driver.takesBackQueue)
    }
}
