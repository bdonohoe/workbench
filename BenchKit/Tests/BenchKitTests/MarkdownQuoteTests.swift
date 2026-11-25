import Testing
@testable import BenchKit

@MainActor @Test func consecutiveQuoteLinesAreOneQuote() {
    let blocks = MarkdownText.blocks(in: """
    Notes, as submitted:

    > The biggest update yet.
    >
    > • A new look
    > • A rebuilt reader

    After the quote.
    """)
    #expect(blocks == [
        .paragraph("Notes, as submitted:"),
        .quote("The biggest update yet.\n\n• A new look\n• A rebuilt reader"),
        .paragraph("After the quote."),
    ])
}

@MainActor @Test func quoteContentsAreMarkdown() {
    guard case .quote(let inner) = MarkdownText.blocks(in: "> First\n>\n> • one\n> • two\n>> nested").first else {
        Issue.record("Expected a quote")
        return
    }
    #expect(MarkdownText.blocks(in: inner) == [
        .paragraph("First"),
        .bullet(level: 0, "one"),
        .bullet(level: 0, "two"),
        .quote("nested"),
    ])
}

@MainActor @Test func blankLineEndsQuote() {
    #expect(MarkdownText.blocks(in: "> one\n\n> two") == [.quote("one"), .quote("two")])
}
