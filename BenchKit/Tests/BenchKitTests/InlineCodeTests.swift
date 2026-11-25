import SwiftUI
import Testing
@testable import BenchKit

@Test func codeSpansAreFoundAndMadeCopyable() {
    let parsed = MarkdownText.parseInline("Set `STRIPE_SECRET_KEY` then run `railway up`.")
    let styled = InlineStyle(parsed, codeFont: nil, codeColor: .blue)
    #expect(styled.code.map(\.text) == ["STRIPE_SECRET_KEY", "railway up"])
    #expect(styled.code.map(\.range) == [4..<21, 31..<41])
    #expect(styled.links.isEmpty)
    let urls = styled.text.runs.compactMap(\.link)
    #expect(urls.map(\.absoluteString) == ["bench-copy://0", "bench-copy://1"])
}

@Test func codeInsideALinkStaysALink() {
    let parsed = MarkdownText.parseInline("See [`README.md`](https://example.com) and `make build`.")
    let styled = InlineStyle(parsed, codeFont: nil, codeColor: .blue)
    #expect(styled.code.map(\.text) == ["make build"])
    #expect(styled.links.count == 1)
}
