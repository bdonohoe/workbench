import AppKit
import BenchKit
import SwiftUI

/// A diff in one text view, so text can be selected across lines, copied
/// without its line numbers, and searched with ⌘F. The gutter shows the old
/// and new line numbers; added and removed lines get a band behind them and
/// their changed words a stronger highlight.
struct DiffTextView: NSViewRepresentable {
    let layout: DiffLayout
    /// The file's path, so its code can be colored for its language.
    var path: String?
    /// Word-level breakdown per line, parallel to `layout.ranges`. Empty means plain.
    let segments: [[DiffLine.Segment]]
    /// Old and new line numbers per line, parallel to `layout.ranges`.
    let oldNumbers: [Int?]
    let newNumbers: [Int?]
    let wraps: Bool
    /// Lines (by index) that have comments, marked in the gutter.
    let commentedLines: Set<Int>
    /// The line a comment is being written for, if any.
    let composing: Int?
    /// Rows standing in for folded unchanged lines, by index; a click opens one.
    var folds: Set<Int> = []
    var onFold: (Int) -> Void = { _ in }
    /// File header rows in a review, by index.
    var headers: Set<Int> = []
    /// In a review, each file's lines and its path, for coloring its code.
    /// A diff of one file gives `path` instead.
    var sections: [SyntaxColors.Section] = []
    /// The latest request to scroll a line to the top.
    var reveal = LineReveal()
    var onTopLine: ((Int) -> Void)?
    /// The latest request to move to the next or previous change.
    var jump = ChangeJump()
    /// Called when a jump finds no more changes that way.
    var onRunOut: (Bool) -> Void = { _ in }
    let onComment: (Int) -> Void

    final class Coordinator {
        var applied: Applied?
        var jump = 0
        var reveal = 0
    }

    struct Applied: Equatable {
        var layout: DiffLayout
        var segments: [[DiffLine.Segment]]
        var folds: Set<Int>
        var headers: Set<Int>
        var added: NSColor
        var removed: NSColor
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> CodeTextContainer {
        let view = CodeTextContainer(source: DiffGutter())
        view.onComment = onComment
        view.onFold = onFold
        view.setWraps(wraps)
        return view
    }

    func updateNSView(_ view: CodeTextContainer, context: Context) {
        guard let gutter = view.source as? DiffGutter else { return }
        view.onComment = onComment
        view.onFold = onFold
        view.onTopLine = onTopLine
        view.setBackground(TerminalTheme.shared.nsCanvas)
        view.setWraps(wraps)

        let added = Self.addedColor, removed = Self.removedColor
        let next = Applied(layout: layout, segments: segments, folds: folds, headers: headers, added: added, removed: removed)
        if context.coordinator.applied != next {
            context.coordinator.applied = next
            gutter.prepare(layout: layout, oldNumbers: oldNumbers, newNumbers: newNumbers, folds: folds, headers: headers,
                           added: added, removed: removed)
            let text = Self.attributedText(layout: layout, segments: segments, folds: folds, headers: headers,
                                           added: added, removed: removed)
            view.setAttributedText(text)
            if path != nil || !sections.isEmpty {
                let layout = layout, string = text.string, path = path, sections = sections
                Task {
                    let found = if let path { await SyntaxColors.spans(in: layout, path: path) }
                                else { await SyntaxColors.spans(in: layout, sections: sections) }
                    guard let found else { return }
                    view.applySyntax(found, to: string)
                }
            }
        }
        if gutter.commentedLines != commentedLines || gutter.composing != composing {
            gutter.commentedLines = commentedLines
            gutter.composing = composing
            view.refreshDecorations()
        }
        if reveal.id != context.coordinator.reveal {
            context.coordinator.reveal = reveal.id
            view.scroll(toLine: reveal.line)
        }
        if jump.id != context.coordinator.jump {
            context.coordinator.jump = jump.id
            if !view.jump(to: DiffFolding.changeStarts(layout.kinds), forward: jump.forward) {
                let forward = jump.forward
                DispatchQueue.main.async { onRunOut(forward) }
            }
        }
    }

    // MARK: Colors

    /// Green from the terminal theme when matching it, else the app's "done" green.
    static var addedColor: NSColor { NSColor(TerminalTheme.shared.ansiColor(2) ?? Theme.Status.done) }
    /// Red from the terminal theme when matching it, else the app's "failed" red.
    static var removedColor: NSColor { NSColor(TerminalTheme.shared.ansiColor(1) ?? Theme.Status.failed) }

    /// `base` at the alpha for a band, a gutter tint or a word highlight,
    /// resolved for the appearance it's drawn in.
    static func tint(_ base: NSColor, light: CGFloat, dark: CGFloat) -> NSColor {
        NSColor(name: nil) { @Sendable appearance in
            var resolved = base
            appearance.performAsCurrentDrawingAppearance { resolved = base.usingColorSpace(.sRGB) ?? base }
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return resolved.withAlphaComponent(isDark ? dark : light)
        }
    }

    static let hunkBand = NSColor.labelColor.withAlphaComponent(0.04)

    // MARK: Text

    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    private static let metaFont: NSFont = {
        let descriptor = font.fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }()

    private static let headerFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)

    private static let headerParagraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = 14
        style.paragraphSpacing = 6
        return style
    }()

    private static let hunkParagraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = 4
        style.paragraphSpacing = 4
        return style
    }()

    static func attributedText(layout: DiffLayout, segments: [[DiffLine.Segment]], folds: Set<Int> = [],
                               headers: Set<Int> = [], added: NSColor, removed: NSColor) -> NSAttributedString {
        let text = NSMutableAttributedString(string: layout.text, attributes: [.font: font, .foregroundColor: NSColor.textColor])
        let length = text.length
        let addedWords = tint(added, light: 0.30, dark: 0.35)
        let removedWords = tint(removed, light: 0.30, dark: 0.35)
        for (index, range) in layout.ranges.enumerated() {
            switch layout.kinds[index] {
            case .hunk where headers.contains(index):
                // A file's header in a review: its path in the text color,
                // then its counts in green and red.
                let paragraph = NSRange(location: range.location, length: min(range.length + 1, length - range.location))
                text.addAttributes([.font: headerFont, .paragraphStyle: headerParagraph], range: paragraph)
                let line = (layout.text as NSString).substring(with: range) as NSString
                let plus = line.range(of: "  +", options: .backwards)
                if plus.location != NSNotFound {
                    let counts = NSRange(location: range.location + plus.location, length: range.length - plus.location)
                    text.addAttribute(.foregroundColor, value: added, range: counts)
                    let minus = line.range(of: " −", options: .backwards)
                    if minus.location != NSNotFound, minus.location > plus.location {
                        text.addAttribute(.foregroundColor, value: removed,
                                          range: NSRange(location: range.location + minus.location, length: range.length - minus.location))
                    }
                }
            case .hunk:
                // The whole paragraph, newline included, so the spacing applies.
                let paragraph = NSRange(location: range.location, length: min(range.length + 1, length - range.location))
                text.addAttributes([.foregroundColor: folds.contains(index) ? NSColor.linkColor : NSColor.secondaryLabelColor,
                                    .paragraphStyle: hunkParagraph], range: paragraph)
            case .meta:
                text.addAttributes([.foregroundColor: NSColor.secondaryLabelColor, .font: metaFont], range: range)
            case .added, .removed:
                guard index < segments.count, !segments[index].isEmpty else { continue }
                let highlight = layout.kinds[index] == .added ? addedWords : removedWords
                var offset = range.location
                for segment in segments[index] {
                    let count = segment.text.utf16.count
                    if segment.changed, offset + count <= NSMaxRange(range) {
                        text.addAttribute(.backgroundColor, value: highlight, range: NSRange(location: offset, length: count))
                    }
                    offset += count
                }
            case .context:
                break
            }
        }
        return text
    }
}

/// Two columns of line numbers, old and new, with each changed line tinted
/// more strongly than its band in the text, "⋯" on hunk lines, and marks on
/// lines with comments.
final class DiffGutter: GutterSource {
    private(set) var lineStarts: [Int] = []
    private(set) var width: CGFloat = 70
    private var kinds: [DiffLine.Kind] = []
    private var oldNumbers: [Int?] = []
    private var newNumbers: [Int?] = []
    private var addedBand = NSColor.clear, addedTint = NSColor.clear
    private var removedBand = NSColor.clear, removedTint = NSColor.clear
    var commentedLines: Set<Int> = []
    var composing: Int?

    private let font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
    private var columnWidth: CGFloat = 27
    private static let trailing: CGFloat = 8

    private var folds: Set<Int> = []
    private var headers: Set<Int> = []

    func prepare(layout: DiffLayout, oldNumbers: [Int?], newNumbers: [Int?], folds: Set<Int> = [], headers: Set<Int> = [],
                 added: NSColor, removed: NSColor) {
        lineStarts = layout.ranges.map(\.location)
        self.folds = folds
        self.headers = headers
        kinds = layout.kinds
        self.oldNumbers = oldNumbers
        self.newNumbers = newNumbers
        addedBand = DiffTextView.tint(added, light: 0.12, dark: 0.12)
        removedBand = DiffTextView.tint(removed, light: 0.12, dark: 0.12)
        addedTint = DiffTextView.tint(added, light: 0.22, dark: 0.22)
        removedTint = DiffTextView.tint(removed, light: 0.22, dark: 0.22)
        let largest = max(oldNumbers.compactMap { $0 }.max() ?? 0, newNumbers.compactMap { $0 }.max() ?? 0)
        let digits = max(3, String(largest).count)
        columnWidth = CGFloat(digits) * 7 + 6
        width = columnWidth * 2 + Self.trailing
    }

    /// The text is set from the layout, so there's nothing to recount here.
    func textChanged(_ text: String) {}

    func lineBackground(_ line: Int) -> NSColor? {
        guard line < kinds.count else { return nil }
        switch kinds[line] {
        case .added: return addedBand
        case .removed: return removedBand
        case .hunk: return DiffTextView.hunkBand
        case .context, .meta: return nil
        }
    }

    func isFold(_ line: Int) -> Bool { folds.contains(line) }

    func canComment(_ line: Int) -> Bool {
        guard line < kinds.count else { return false }
        switch kinds[line] {
        case .added, .removed, .context: return true
        case .hunk, .meta: return false
        }
    }

    func drawCell(line: Int, in row: NSRect, firstLine: NSRect) {
        guard line < kinds.count else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
        switch kinds[line] {
        case .added:
            addedTint.setFill()
            row.fill()
        case .removed:
            removedTint.setFill()
            row.fill()
        case .hunk:
            DiffTextView.hunkBand.setFill()
            row.fill()
            if headers.contains(line) { return }
            let mark = "⋯" as NSString
            let marker: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
            let size = mark.size(withAttributes: marker)
            mark.draw(at: NSPoint(x: row.maxX - Self.trailing - size.width - 2, y: firstLine.midY - size.height / 2), withAttributes: marker)
            return
        case .context, .meta:
            break
        }
        if let old = oldNumbers[line] {
            draw(number: old, rightEdge: columnWidth - 3, in: firstLine, attributes: attributes)
        }
        if let new = newNumbers[line] {
            draw(number: new, rightEdge: columnWidth * 2 - 3, in: firstLine, attributes: attributes)
        }
        if line == composing {
            NSColor(Theme.accent).setFill()
            NSRect(x: 0, y: row.minY, width: 2, height: row.height).fill()
        } else if commentedLines.contains(line) {
            NSColor(Theme.accent).setFill()
            NSBezierPath(ovalIn: NSRect(x: 4, y: firstLine.midY - 2.5, width: 5, height: 5)).fill()
        }
    }

    private func draw(number: Int, rightEdge: CGFloat, in firstLine: NSRect, attributes: [NSAttributedString.Key: Any]) {
        let label = String(number) as NSString
        let size = label.size(withAttributes: attributes)
        label.draw(at: NSPoint(x: rightEdge - size.width, y: firstLine.minY + (firstLine.height - size.height) / 2), withAttributes: attributes)
    }
}
