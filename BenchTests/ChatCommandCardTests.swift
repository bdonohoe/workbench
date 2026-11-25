import BenchKit
import Foundation
import Testing
@testable import Bench

/// `/help` in the chat lists every command, grouped by where it comes from.
struct ChatHelpCardTests {
    @Test func commandsAreGroupedBySourceWithClaudeCodesFirst() {
        let sections = ChatHelpCard.sections([
            SlashCommand(name: "vercel:deploy", description: "", source: .plugin),
            SlashCommand(name: "unslop", description: "", source: .user),
            SlashCommand(name: "resume", description: "", source: .builtIn),
            SlashCommand(name: "ship", description: "", source: .project),
            SlashCommand(name: "clear", description: "", source: .builtIn),
            SlashCommand(name: "posthog:signals", description: "", source: .plugin),
        ])
        #expect(sections.map(\.title) == ["Claude Code", "This project", "Yours", "posthog", "vercel"])
        #expect(sections[0].commands.map(\.name) == ["clear", "resume"])
    }

    @Test func emptyGroupsAreLeftOut() {
        let sections = ChatHelpCard.sections([SlashCommand(name: "clear", description: "", source: .builtIn)])
        #expect(sections.map(\.title) == ["Claude Code"])
    }
}

/// The file name `/export` suggests in its save panel.
struct ExportNameTests {
    private let day = Date(timeIntervalSince1970: 1_794_700_800)  // 2026-11-15 UTC

    @Test func theNameIsTheTabsTitleAndTheDay() {
        let name = ExportName.suggested(title: "Fix sidebar", on: day)
        #expect(name.hasPrefix("Fix sidebar 2026-11-1"))
        #expect(name.hasSuffix(".txt"))
    }

    @Test func charactersAFileNameCantHoldAreReplaced() {
        #expect(ExportName.suggested(title: "a/b: c", on: day).hasPrefix("a-b- c "))
        #expect(ExportName.suggested(title: nil, on: day).hasPrefix("Conversation "))
        #expect(ExportName.suggested(title: "  ", on: day).hasPrefix("Conversation "))
        // Claude Code's mark at the start of a tab's title is left off.
        #expect(ExportName.suggested(title: "✳ Fix sidebar", on: day).hasPrefix("Fix sidebar 2026"))
    }
}
