import Foundation
import SwiftUI
import Testing
@testable import BenchKit

@MainActor @Test func colorsBareURLsAndMarkdownLinks() {
    let text = MarkdownText.parseInline("See https://a.com and [this](https://b.com), not this.")
    let links = text.runs.filter { $0.link != nil }
    #expect(links.count == 2)
    #expect(links.allSatisfy { $0.foregroundColor == StepColors.link })
    #expect(text.runs.filter { $0.link == nil }.allSatisfy { $0.foregroundColor == nil })
}

@MainActor @Test func findsLinksInUTF16Offsets() {
    // 😀 is two UTF-16 units, which a layout's character indices count.
    let text = MarkdownText.parseInline("😀 [a link](https://a.com) and https://b.com")
    #expect(MarkdownText.linkRanges(in: text) == [3..<9, 14..<27])
}

@MainActor @Test func plainTextHasNoLinks() {
    #expect(MarkdownText.linkRanges(in: MarkdownText.parseInline("**bold** and `code`")).isEmpty)
}
