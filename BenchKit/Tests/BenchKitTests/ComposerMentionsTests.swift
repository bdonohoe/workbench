import Testing
@testable import BenchKit

@Suite struct ComposerTokenTests {
    private func token(_ marked: String) -> ComposerToken? {
        // "|" marks the cursor.
        let caret = marked.utf16.firstIndex(of: "|".utf16.first!).map { marked.utf16.distance(from: marked.utf16.startIndex, to: $0) }!
        return ComposerToken.at(caret, in: marked.replacingOccurrences(of: "|", with: ""))
    }

    @Test func findsACommandMidMessage() {
        let found = token("use /uns| for this")
        #expect(found?.kind == .command)
        #expect(found?.query == "uns")
        #expect(found?.isWholeMessage == false)
    }

    @Test func findsAFileAndTheRestOfItsWord() throws {
        let text = "look at @Sour/App.swift please"
        let found = try #require(ComposerToken.at(13, in: text))
        #expect(found.kind == .file)
        #expect(found.query == "Sour")
        #expect(text[found.range] == "@Sour/App.swift")
    }

    @Test func aCommandAloneIsTheWholeMessage() {
        #expect(token("/comp|")?.isWholeMessage == true)
        #expect(token("|")?.kind == nil)
    }

    @Test func ignoresAddressesPathsAndFinishedWords() {
        #expect(token("mail matt@birch|") == nil)
        #expect(token("in src/ap|") == nil)
        #expect(token("/usr/bi|") == nil)
        #expect(token("use /unslop |") == nil)
    }

    @Test func worksAfterEmojiAndNewlines() {
        #expect(token("👋🏽 hi\n@Rea|")?.query == "Rea")
    }
}

@Suite struct FileMentionTests {
    private let mentions = FileMention.all(from: [
        "README.md", "Makefile", "Sources/App.swift", "Sources/Views/AppView.swift",
        "Tests/AppTests.swift", "docs/My Notes.md",
    ])

    @Test func listsFoldersToo() {
        #expect(mentions.contains(FileMention(path: "Sources/Views", isDirectory: true)))
        #expect(mentions.contains(FileMention(path: "Sources", isDirectory: true)))
    }

    @Test func nothingTypedShowsTheTopOfTheProject() {
        let found = FileMention.matches(query: "", in: mentions).map(\.path)
        #expect(Set(found) == ["README.md", "Makefile", "Sources", "Tests", "docs"])
    }

    @Test func namesStartingWithTheQueryComeFirst() {
        let found = FileMention.matches(query: "app", in: mentions).map(\.path)
        #expect(found.first == "Sources/App.swift")
        #expect(found.contains("Tests/AppTests.swift"))
    }

    @Test func aSlashMatchesWhatsInsideAFolder() {
        let found = FileMention.matches(query: "sources/", in: mentions).map(\.path)
        #expect(found.first == "Sources/App.swift" || found.first == "Sources/Views")
        #expect(!found.contains("Sources"))
        #expect(found.contains("Sources/Views/AppView.swift"))
    }

    @Test func insertionEndsTheWayClaudeCodeReadsIt() {
        #expect(FileMention(path: "Sources/App.swift", isDirectory: false).insertion == "@Sources/App.swift ")
        #expect(FileMention(path: "Sources", isDirectory: true).insertion == "@Sources/")
        #expect(FileMention(path: "docs/My Notes.md", isDirectory: false).insertion == "@\"docs/My Notes.md\" ")
    }
}

@Suite struct MidMessageCommandTests {
    @Test func sessionCommandsOnlyWorkAlone() {
        let clear = SlashCommand.builtIn.first { $0.name == "clear" }!
        let review = SlashCommand.builtIn.first { $0.name == "code-review" }!
        let skill = SlashCommand(name: "unslop", description: "", source: .user)
        #expect(!clear.worksMidMessage)
        #expect(review.worksMidMessage)
        #expect(skill.worksMidMessage)
    }
}

@Suite struct ReadyToSendTests {
    @Test func endingOnAFileMentionGetsASpace() {
        #expect(ComposerToken.readyToSend("look at @~/Work/app/") == "look at @~/Work/app/ ")
        #expect(ComposerToken.readyToSend("first line\nsee @Sources/App.swift") == "first line\nsee @Sources/App.swift ")
    }

    @Test func otherMessagesAreLeftAlone() {
        #expect(ComposerToken.readyToSend("look at @~/Work/app please") == "look at @~/Work/app please")
        #expect(ComposerToken.readyToSend("/compact") == "/compact")
        #expect(ComposerToken.readyToSend("mail me@example.com") == "mail me@example.com")
        #expect(ComposerToken.readyToSend("") == "")
    }
}
