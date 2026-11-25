import Foundation
import Testing
@testable import BenchKit

@MainActor @Test func exportsBlocksAsHTML() {
    let html = MarkdownExport.html("""
    ## Title
    Some **bold** and `code` and [a link](https://a.com).

    - one
      - inner
    - two
    3. three
    4. four

    > quoted

    | A | B |
    |---|---|
    | 1 | 2 |

    ```
    a < b
    ```
    """)
    #expect(html.contains("<h2>Title</h2>"))
    #expect(html.contains("<p>Some <strong>bold</strong> and <code>code</code> and <a href=\"https://a.com\">a link</a>.</p>"))
    #expect(html.contains("<ul><li>one<ul><li>inner</li></ul></li><li>two</li></ul><ol start=\"3\"><li>three</li><li>four</li></ol>"))
    #expect(html.contains("<blockquote><p>quoted</p></blockquote>"))
    #expect(html.contains("<table><thead><tr><th>A</th><th>B</th></tr></thead><tbody><tr><td>1</td><td>2</td></tr></tbody></table>"))
    #expect(html.contains("<pre><code>a &lt; b</code></pre>"))
}

@MainActor @Test func aLonePhraseIsNotAParagraph() {
    #expect(MarkdownExport.html("just *this*") == "just <em>this</em>")
}

#if os(macOS)
import AppKit

@MainActor private func prose(_ markdown: String) -> NSAttributedString {
    let fonts = ProseFonts(textFamily: nil, codeFamily: nil, bodySize: 13, codeSize: 12,
                           heading1Size: 20, heading2Size: 17, heading3Size: 15, lineSpacing: 2, scale: 1)
    let colors = ProseColors(ink: .white, muted: .gray, code: .orange, link: .blue)
    return ProseBuilder(fonts: fonts, colors: colors).build(MarkdownText.blocks(in: markdown))
}

@MainActor private func copied(_ text: NSAttributedString, _ part: String? = nil) -> ProseCopy.Copied {
    let string = text.string as NSString
    let range = part.map { string.range(of: $0) } ?? NSRange(location: 0, length: string.length)
    return ProseCopy.copied(in: text, range: range)
}

@MainActor @Test func selectingAcrossBlocksCopiesTheirMarkdown() {
    let source = """
    ## Title

    Some **bold**, `code` and [a link](https://a.com).

    - one
      - [ ] inner
    - two
    1. first
    2. second
    """
    #expect(copied(prose(source)) == .init(text: source, isMarkdown: true))
}

@MainActor @Test func selectingWithinALineKeepsItsFormattingButNotItsMarker() {
    let text = prose("- an item with **bold** in it\n- another")
    #expect(copied(text, "item with bold in") == .init(text: "item with **bold** in", isMarkdown: true))
}

@MainActor @Test func selectingOneStyleCopiesBareText() {
    let text = prose("Call `__init__` on the **very thing** here")
    #expect(copied(text, "__init__") == .init(text: "__init__", isMarkdown: false))
    #expect(copied(text, "very") == .init(text: "very", isMarkdown: false))
    #expect(copied(text, "on the") == .init(text: "on the", isMarkdown: false))
}

@MainActor @Test func aBlockSelectedFromItsMiddleHasNoMarker() {
    let text = prose("## A heading\n\nA paragraph")
    #expect(copied(text, "heading\nA para") == .init(text: "heading\n\nA para", isMarkdown: true))
}

@MainActor @Test func literalAsterisksAreEscaped() {
    let text = prose(#"2 \* 3 and **bold** and snake_case and \_x\_"#)
    #expect(copied(text).text == #"2 \* 3 and **bold** and snake_case and \_x\_"#)
}

@MainActor @Test func copyingASelectionWritesMarkdownAndHTML() {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let view = ProseNSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
    view.textStorage?.setAttributedString(prose("# Title\n\nSee [docs](https://a.com)"))
    view.setSelectedRange(NSRange(location: 0, length: view.string.utf16.count))
    #expect(view.writeSelection(to: pasteboard, types: [.string]))
    #expect(pasteboard.string(forType: .string) == "# Title\n\nSee [docs](https://a.com)")
    #expect(pasteboard.string(forType: .html) == "<meta charset=\"utf-8\"><h1>Title</h1>\n<p>See <a href=\"https://a.com\">docs</a></p>")
}
#endif
