import Foundation
import Testing
@testable import BenchKit

@Suite struct MarkdownTildeTests {
    private func struck(_ text: AttributedString) -> Bool {
        text.runs.contains { $0.inlinePresentationIntent?.contains(.strikethrough) == true }
    }

    @Test func homePathsKeepTheirTildes() {
        let line = "look at these sister projects @~/Work/agent-dsl @~/Work/service-agentic-reasoner/"
        let parsed = MarkdownText.parseInline(line)
        #expect(String(parsed.characters) == line)
        #expect(!struck(parsed))
    }

    @Test func roughNumbersKeepTheirTildes() {
        let parsed = MarkdownText.parseInline("takes ~5 to ~10 minutes")
        #expect(String(parsed.characters) == "takes ~5 to ~10 minutes")
        #expect(!struck(parsed))
    }

    @Test func doubleTildesStillStrikeThrough() {
        let parsed = MarkdownText.parseInline("this is ~~gone~~ now")
        #expect(String(parsed.characters) == "this is gone now")
        #expect(struck(parsed))
    }

    @Test func webAddressesKeepTheirTildes() {
        let line = "clone https://git.sr.ht/~sircmpwn/scdoc or see www.example.com/~me/page, about ~5 MB"
        let parsed = MarkdownText.parseInline(line)
        #expect(String(parsed.characters) == line)
        #expect(!struck(parsed))
        let links = parsed.runs.compactMap { $0.link?.absoluteString }
        #expect(links == ["https://git.sr.ht/~sircmpwn/scdoc", "http://www.example.com/~me/page"])
        // Two addresses on a line don't strike through what's between them.
        let two = MarkdownText.parseInline("(https://a.com/~x) and [b](https://b.com/~y)")
        #expect(String(two.characters) == "(https://a.com/~x) and b")
        #expect(!struck(two))
        #expect(two.runs.compactMap { $0.link?.absoluteString } == ["https://a.com/~x", "https://b.com/~y"])
        // A tilde before the address on the same word is still a lone tilde.
        #expect(MarkdownText.escapingLoneTildes("~https://a.com") == "\\~https://a.com")
    }

    @Test func codeSpansAndAutolinksAreUntouched() {
        #expect(MarkdownText.escapingLoneTildes("run `ls ~/a ~/b` then ~x") == "run `ls ~/a ~/b` then \\~x")
        #expect(MarkdownText.escapingLoneTildes("see <https://example.com/~me>") == "see <https://example.com/~me>")
        #expect(MarkdownText.escapingLoneTildes("already \\~ escaped") == "already \\~ escaped")
        let parsed = MarkdownText.parseInline("run `ls ~/a ~/b` now")
        #expect(String(parsed.characters) == "run ls ~/a ~/b now")
    }
}
