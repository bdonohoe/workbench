import Testing
@testable import BenchKit

@Test func entriesAreYourMessagesOldestFirst() {
    let turns = TranscriptTurn.group([
        TranscriptMessage(id: "1", role: .user, text: "first"),
        TranscriptMessage(id: "2", role: .assistant, text: "Sure."),
        TranscriptMessage(id: "3", role: .user, text: "  second  \n"),
        TranscriptMessage(id: "4", role: .assistant, text: "Done."),
    ])
    #expect(ComposerHistory.entries(from: turns) == ["first", "second"])
}

@Test func entriesSkipBlanksAndRepeats() {
    let turns = TranscriptTurn.group([
        TranscriptMessage(id: "1", role: .user, text: "again"),
        TranscriptMessage(id: "2", role: .assistant, text: "ok"),
        TranscriptMessage(id: "3", role: .user, text: "again"),
        TranscriptMessage(id: "4", role: .assistant, text: "ok"),
        TranscriptMessage(id: "5", role: .user, text: "   "),
        TranscriptMessage(id: "6", role: .user, text: "new"),
    ])
    #expect(ComposerHistory.entries(from: turns) == ["again", "new"])
}

@Test func upWalksBackAndStopsAtTheOldest() {
    var history = ComposerHistory(entries: ["one", "two", "three"])
    #expect(history.up(from: "") == "three")
    #expect(history.up(from: "three") == "two")
    #expect(history.up(from: "two") == "one")
    #expect(history.up(from: "one") == nil)
    #expect(history.position == 0)
}

@Test func downComesBackToWhatYouTyped() {
    var history = ComposerHistory(entries: ["one", "two"])
    #expect(history.down() == nil)
    #expect(history.up(from: "half a thou") == "two")
    #expect(history.up(from: "two") == "one")
    #expect(history.down() == "two")
    #expect(history.down() == "half a thou")
    #expect(!history.isBrowsing)
    #expect(history.down() == nil)
}

@Test func typingLeavesTheHistory() {
    var history = ComposerHistory(entries: ["one", "two"])
    _ = history.up(from: "")
    // The box taking the recalled text isn't typing.
    history.draftChanged(to: "two")
    #expect(history.isBrowsing)
    history.draftChanged(to: "two, but better")
    #expect(!history.isBrowsing)
    // The next up starts from the newest again, with the edit kept below.
    #expect(history.up(from: "two, but better") == "two")
    #expect(history.down() == "two, but better")
}

@Test func emptyHistoryDoesNothing() {
    var history = ComposerHistory()
    #expect(history.up(from: "draft") == nil)
    #expect(history.down() == nil)
    #expect(!history.isBrowsing)
}

@Test func newMessagesKeepTheRecalledOneInPlace() {
    var history = ComposerHistory(entries: ["one", "two"])
    #expect(history.up(from: "") == "two")
    #expect(history.up(from: "two") == "one")
    history.update(entries: ["one", "two", "three"])
    #expect(history.position == 0)
    #expect(history.down() == "two")
    #expect(history.down() == "three")
    #expect(history.down() == "")
}

@Test func aRecalledMessageThatVanishesEndsBrowsing() {
    var history = ComposerHistory(entries: ["one", "two"])
    #expect(history.up(from: "") == "two")
    history.update(entries: ["one"])
    #expect(!history.isBrowsing)
    #expect(history.up(from: "two") == "one")
}
