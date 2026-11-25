import AppKit
import Testing
@testable import Bench

/// Up and down only recall sent messages from the box's top and bottom
/// lines, counting lines a long paragraph wraps onto.
@MainActor
struct ComposerLinesTests {
    private func editor(_ text: String, caret: Int) -> (NSTextView, NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        view.font = .systemFont(ofSize: 13)
        window.contentView = view
        view.string = text
        view.setSelectedRange(NSRange(location: caret, length: 0))
        return (view, window)
    }

    private let paragraph = String(repeating: "word ", count: 60)

    @Test func wrappedParagraphMiddleIsNeitherFirstNorLast() {
        let (view, window) = editor(paragraph, caret: 150)
        defer { window.close() }
        #expect(!ComposerLines.caretIsOnFirstLine(of: view))
        #expect(!ComposerLines.caretIsOnLastLine(of: view))
    }

    @Test func wrappedParagraphEnds() {
        let (start, w1) = editor(paragraph, caret: 3)
        defer { w1.close() }
        #expect(ComposerLines.caretIsOnFirstLine(of: start))
        #expect(!ComposerLines.caretIsOnLastLine(of: start))
        let (end, w2) = editor(paragraph, caret: paragraph.count - 2)
        defer { w2.close() }
        #expect(!ComposerLines.caretIsOnFirstLine(of: end))
        #expect(ComposerLines.caretIsOnLastLine(of: end))
    }

    @Test func shortLinesAndBreaks() {
        let (empty, w1) = editor("", caret: 0)
        defer { w1.close() }
        #expect(ComposerLines.caretIsOnFirstLine(of: empty))
        #expect(ComposerLines.caretIsOnLastLine(of: empty))
        let (second, w2) = editor("one\ntwo", caret: 5)
        defer { w2.close() }
        #expect(!ComposerLines.caretIsOnFirstLine(of: second))
        #expect(ComposerLines.caretIsOnLastLine(of: second))
    }

    @Test func aSelectionNeverRecalls() {
        let (view, window) = editor("hello", caret: 0)
        defer { window.close() }
        view.setSelectedRange(NSRange(location: 0, length: 3))
        #expect(!ComposerLines.caretIsOnFirstLine(of: view))
    }
}
