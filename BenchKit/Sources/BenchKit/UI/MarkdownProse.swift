#if os(macOS)
import AppKit
import SwiftUI

/// The fonts for a run of Markdown prose drawn as one Mac text view. Set
/// where the chat has its own type; without them, each line is its own
/// SwiftUI Text, which can only be selected one at a time.
public struct ProseFonts: Sendable, Equatable {
    /// Families as chosen in Settings, nil for the system's fonts.
    public var textFamily: String?
    public var codeFamily: String?
    /// Sizes at 100%.
    public var bodySize: CGFloat
    public var codeSize: CGFloat
    public var heading1Size: CGFloat
    public var heading2Size: CGFloat
    public var heading3Size: CGFloat
    public var lineSpacing: CGFloat
    /// 1 is the usual size.
    public var scale: CGFloat

    public init(textFamily: String?, codeFamily: String?, bodySize: CGFloat, codeSize: CGFloat,
                heading1Size: CGFloat, heading2Size: CGFloat, heading3Size: CGFloat, lineSpacing: CGFloat, scale: CGFloat) {
        self.textFamily = textFamily
        self.codeFamily = codeFamily
        self.bodySize = bodySize
        self.codeSize = codeSize
        self.heading1Size = heading1Size
        self.heading2Size = heading2Size
        self.heading3Size = heading3Size
        self.lineSpacing = lineSpacing
        self.scale = scale
    }

    func text(_ size: CGFloat, weight: NSFont.Weight = .regular, rounded: Bool = false) -> NSFont {
        let size = size * scale
        if let family = textFamily,
           let font = NSFontManager.shared.font(withFamily: family, traits: weight >= .semibold ? .boldFontMask : [],
                                                weight: weight >= .semibold ? 9 : 5, size: size) {
            return font
        }
        let system = NSFont.systemFont(ofSize: size, weight: weight)
        guard rounded, let descriptor = system.fontDescriptor.withDesign(.rounded) else { return system }
        return NSFont(descriptor: descriptor, size: size) ?? system
    }

    func code(weight: NSFont.Weight = .regular) -> NSFont {
        let size = codeSize * scale
        if let family = codeFamily, let font = NSFont(name: family, size: size) { return font }
        return .monospacedSystemFont(ofSize: size, weight: weight)
    }

    func heading(_ level: Int) -> NSFont {
        switch level {
        case 1: text(heading1Size, weight: .bold, rounded: true)
        case 2: text(heading2Size, weight: .bold, rounded: true)
        default: text(heading3Size, weight: .semibold, rounded: true)
        }
    }
}

extension NSAttributedString.Key {
    /// Marks a `code` span, holding the text it copies.
    static let benchCode = NSAttributedString.Key("BenchCode")
    /// On a whole block, the Markdown that starts its line: "## ", "  - ".
    static let benchPrefix = NSAttributedString.Key("BenchPrefix")
    /// Marks a list item's drawn bullet or number, which isn't its text.
    static let benchMarker = NSAttributedString.Key("BenchMarker")
    /// A run's bold, italic and so on, as an InlinePresentationIntent's raw value.
    static let benchInline = NSAttributedString.Key("BenchInline")
}

/// Paragraphs, headings and list items from one reply as a single text
/// view, so a drag can select across all of them and copy them together.
/// Code spans keep their tinted chip and copy (or show the file they
/// name) when clicked; links open as usual.
struct ProseText: View {
    @Environment(\.companionPalette) private var palette
    @Environment(\.revealStepFile) private var revealFile
    @Environment(\.openURL) private var openURL
    // Only the color scheme, not the whole environment: reading all of it
    // redrew every reply on screen whenever anything in it changed.
    @Environment(\.colorScheme) private var colorScheme
    let blocks: [MarkdownText.Block]
    let fonts: ProseFonts
    /// One color for everything, for text on a colored bubble.
    var ink: Color?
    @State private var copiedRect: CGRect?
    @State private var copies = 0
    /// The text as last built, since building it styles every run again.
    @State private var built = Built()

    private final class Built {
        var key: Key?
        var text = NSAttributedString()
    }

    private struct Key: Equatable {
        var blocks: [MarkdownText.Block]
        var fonts: ProseFonts
        var colors: ProseColors
    }

    private func text(colors: ProseColors) -> NSAttributedString {
        let key = Key(blocks: blocks, fonts: fonts, colors: colors)
        if built.key != key {
            built.text = ProseBuilder(fonts: fonts, colors: colors).build(blocks)
            built.key = key
        }
        return built.text
    }

    private var colors: ProseColors {
        var environment = EnvironmentValues()
        environment.colorScheme = colorScheme
        let resolve = { (color: Color) in NSColor(Color(color.resolve(in: environment))) }
        if let ink {
            let one = resolve(ink)
            return ProseColors(ink: one, muted: one.withAlphaComponent(0.7), code: one, link: one)
        }
        return ProseColors(ink: resolve(palette.ink), muted: resolve(palette.inkMuted),
                           code: resolve(palette.code), link: resolve(StepColors.link))
    }

    var body: some View {
        ProseTextView(text: text(colors: colors),
                      clickedCode: { code, rect in
                          if revealFile?(code) == true { return }
                          NSPasteboard.general.clearContents()
                          NSPasteboard.general.setString(code, forType: .string)
                          copiedRect = rect
                          copies += 1
                          let mine = copies
                          Task {
                              try? await Task.sleep(for: .seconds(1.2))
                              if copies == mine { copiedRect = nil }
                          }
                      },
                      clickedLink: { openURL($0) })
            .overlay(alignment: .topLeading) {
                if let rect = copiedRect {
                    CopiedBubble()
                        .fixedSize()
                        .position(x: rect.midX, y: rect.minY - CopiedBubble.height / 2 - 3)
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.15), value: copiedRect)
    }
}

struct ProseColors: Equatable {
    var ink: NSColor
    var muted: NSColor
    var code: NSColor
    var link: NSColor
}

/// Turns Markdown blocks into one attributed string, with each block a
/// paragraph: list items hang their wrapped lines under the text, not the
/// bullet, and blocks get the same space between them as elsewhere.
@MainActor struct ProseBuilder {
    let fonts: ProseFonts
    let colors: ProseColors

    /// The space between blocks, as in MarkdownText's stack.
    static let blockSpacing: CGFloat = 8

    func build(_ blocks: [MarkdownText.Block]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let body = fonts.text(fonts.bodySize)
        for (index, block) in blocks.enumerated() {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = fonts.lineSpacing
            style.paragraphSpacingBefore = index == 0 ? 0 : Self.blockSpacing
            var marker: String?
            var level = 0
            var base = body
            // What starts this block's line in Markdown, for copying.
            var prefix = ""
            let line: String
            switch block {
            case .paragraph(let text):
                line = text
            case .heading(let headingLevel, let text):
                line = text
                base = fonts.heading(headingLevel)
                prefix = String(repeating: "#", count: headingLevel) + " "
                if index > 0 { style.paragraphSpacingBefore += 4 }
            case .bullet(let itemLevel, let text):
                line = text
                level = itemLevel
                marker = itemLevel == 0 ? "•" : "◦"
                prefix = String(repeating: "  ", count: itemLevel) + "- "
            case .numbered(let itemLevel, let number, let text):
                line = text
                level = itemLevel
                marker = "\(number)."
                prefix = String(repeating: "  ", count: itemLevel) + "\(number). "
            default:
                continue
            }
            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            let blockStart = result.length
            if let marker {
                // The bullet sits at the item's indent, then a tab to where
                // its text starts, which is where wrapped lines start too.
                let indent = 6 + CGFloat(level) * 16
                let markerFont = marker.first?.isNumber == true
                    ? NSFont.monospacedDigitSystemFont(ofSize: body.pointSize, weight: .regular) : body
                let width = (marker as NSString).size(withAttributes: [.font: markerFont]).width
                let textStart = indent + width + 6
                style.firstLineHeadIndent = indent
                style.headIndent = textStart
                style.tabStops = [NSTextTab(textAlignment: .left, location: textStart)]
                style.defaultTabInterval = textStart
                result.append(NSAttributedString(string: marker + "\t", attributes: [
                    .font: markerFont, .foregroundColor: colors.muted, .paragraphStyle: style, .benchMarker: true,
                ]))
            }
            let start = result.length
            result.append(inline(line, base: base))
            result.addAttribute(.paragraphStyle, value: style, range: NSRange(location: start, length: result.length - start))
            result.addAttribute(.benchPrefix, value: prefix, range: NSRange(location: blockStart, length: result.length - blockStart))
        }
        return result
    }

    private func inline(_ line: String, base: NSFont) -> NSAttributedString {
        let parsed = MarkdownCache.shared.inline(line)
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            var font = base
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: colors.ink]
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) {
                font = fonts.code()
                attributes[.foregroundColor] = colors.code
                attributes[.benchCode] = piece
            } else {
                var traits: NSFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if intent.contains(.emphasized) { traits.insert(.italic) }
                if !traits.isEmpty {
                    let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
                    font = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
                }
            }
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if !intent.isEmpty { attributes[.benchInline] = intent.rawValue }
            if let link = run.link {
                attributes[.link] = link
                attributes[.foregroundColor] = colors.link
            }
            attributes[.font] = font
            result.append(NSAttributedString(string: piece, attributes: attributes))
        }
        return result
    }
}

/// The AppKit side: a selectable, read-only text view that's exactly as
/// tall as its text at the width it's given.
private struct ProseTextView: NSViewRepresentable {
    let text: NSAttributedString
    let clickedCode: (String, CGRect) -> Void
    let clickedLink: (URL) -> Void

    func makeNSView(context: Context) -> ProseNSTextView {
        let storage = NSTextStorage()
        let layout = ChipLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layout.addTextContainer(container)
        let view = ProseNSTextView(frame: .zero, textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ view: ProseNSTextView, context: Context) {
        view.clickedCode = clickedCode
        view.clickedLink = clickedLink
        // The same object as last time means the same text: no need to
        // compare every character and attribute.
        guard view.shown !== text else { return }
        view.shown = text
        if !(view.textStorage?.isEqual(to: text) ?? false) {
            view.textStorage?.setAttributedString(text)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: ProseNSTextView, context: Context) -> CGSize? {
        guard let layout = view.layoutManager, let container = view.textContainer else { return nil }
        let width = proposal.width.map { max($0, 1) } ?? 10_000
        if container.size.width != width {
            container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        return CGSize(width: proposal.width ?? ceil(used.width), height: ceil(used.height))
    }
}

/// What a selection of prose copies. The text view's own copy is its
/// drawn text in the chat's fonts and colors: no Markdown, links without
/// their addresses, and white ink in dark mode.
@MainActor enum ProseCopy {
    /// What a selection copies. Within one line that's the line's text
    /// with its bold, code and links marked; across lines the headings and
    /// list items get their markers back too. A selection inside a single
    /// run of one style (a word, a file name in code) is just its text,
    /// since that's nearly always headed somewhere Markdown isn't wanted.
    static func copied(in text: NSAttributedString, range: NSRange) -> Copied {
        let string = text.string as NSString
        let range = NSIntersectionRange(range, NSRange(location: 0, length: string.length))
        guard range.length > 0 else { return Copied(text: "", isMarkdown: false) }
        var lines: [(isItem: Bool, text: String)] = []
        var paragraphs: [NSRange] = []
        var at = range.location
        while at < NSMaxRange(range) {
            var start = 0, end = 0, contentsEnd = 0
            string.getParagraphStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: at, length: 0))
            paragraphs.append(NSRange(location: start, length: contentsEnd - start))
            at = max(end, at + 1)
        }
        let several = paragraphs.count > 1
        if !several, isOneStyle(text, range) {
            return Copied(text: string.substring(with: range), isMarkdown: false)
        }
        for paragraph in paragraphs {
            let selected = NSIntersectionRange(paragraph, range)
            guard paragraph.length > 0 else { continue }
            var textStart = paragraph.location
            while textStart < NSMaxRange(paragraph), text.attribute(.benchMarker, at: textStart, effectiveRange: nil) != nil {
                textStart += 1
            }
            let prefix = text.attribute(.benchPrefix, at: paragraph.location, effectiveRange: nil) as? String ?? ""
            let isItem = !prefix.isEmpty && !prefix.hasPrefix("#")
            let bodyStart = max(selected.location, textStart)
            let bodyRange = NSRange(location: bodyStart, length: max(0, NSMaxRange(selected) - bodyStart))
            guard bodyRange.length > 0 else { continue }
            var body = ""
            text.enumerateAttributes(in: bodyRange) { attributes, run, _ in
                body += inline(string.substring(with: run), attributes: attributes)
            }
            if isItem {
                if body.hasPrefix("☐ ") { body = "[ ] " + body.dropFirst(2) }
                else if body.hasPrefix("☑ ") { body = "[x] " + body.dropFirst(2) }
            }
            // A block picked up from its first word is the whole block.
            let marked = several && selected.location <= textStart
            lines.append((isItem, (marked ? prefix : "") + body))
        }
        var out = ""
        for (index, line) in lines.enumerated() {
            // List items sit on consecutive lines; anything else gets a blank one.
            if index > 0 { out += lines[index - 1].isItem && line.isItem ? "\n" : "\n\n" }
            out += line.text
        }
        return Copied(text: out, isMarkdown: true)
    }

    struct Copied: Equatable {
        var text: String
        /// False for bare text, which mustn't be read as Markdown: copied
        /// code like `__init__` would lose its underscores to bold.
        var isMarkdown: Bool
    }

    /// True when a selection is all one style and none of it a list marker.
    private static func isOneStyle(_ text: NSAttributedString, _ range: NSRange) -> Bool {
        var styles = Set<String>()
        var marker = false
        text.enumerateAttributes(in: range) { attributes, _, _ in
            if attributes[.benchMarker] != nil { marker = true }
            styles.insert("\(attributes[.benchInline] as? UInt ?? 0) \(url(attributes[.link])?.absoluteString ?? "")")
        }
        return !marker && styles.count == 1
    }

    private static func inline(_ piece: String, attributes: [NSAttributedString.Key: Any]) -> String {
        let intent = InlinePresentationIntent(rawValue: attributes[.benchInline] as? UInt ?? 0)
        var result: String
        if intent.contains(.code) {
            // Code holding a backtick needs a longer fence around it.
            result = piece.contains("`") ? "`` \(piece) ``" : "`\(piece)`"
        } else {
            // Markers hug the words: "**bold** " and never "**bold **".
            let core = piece.trimmingCharacters(in: .whitespaces)
            guard !core.isEmpty else { return piece }
            let leading = piece.prefix(while: { $0 == " " })
            let trailing = piece.reversed().prefix(while: { $0 == " " })
            var marks = ""
            if intent.contains(.stronglyEmphasized) { marks += "**" }
            if intent.contains(.emphasized) { marks += "*" }
            if intent.contains(.strikethrough) { marks += "~~" }
            result = marks + escape(core) + String(marks.reversed())
            if let url = url(attributes[.link]) { result = "[\(result)](\(url.absoluteString))" }
            return leading + result + String(trailing)
        }
        if let url = url(attributes[.link]) { result = "[\(result)](\(url.absoluteString))" }
        return result
    }

    private static func url(_ link: Any?) -> URL? {
        (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
    }

    /// Characters that were plain text here but would start formatting if
    /// read back as Markdown.
    private static func escape(_ text: String) -> String {
        let characters = Array(text)
        var out = ""
        for (index, character) in characters.enumerated() {
            switch character {
            case "*", "`", "\\":
                out.append("\\")
            case "_":
                // Inside a word (snake_case) an underscore is only itself.
                let before = index > 0 && (characters[index - 1].isLetter || characters[index - 1].isNumber)
                let after = index + 1 < characters.count && (characters[index + 1].isLetter || characters[index + 1].isNumber)
                if !(before && after) { out.append("\\") }
            default:
                break
            }
            out.append(character)
        }
        return out
    }
}

/// Sends clicks on code and links back to SwiftUI. A drag still selects.
final class ProseNSTextView: NSTextView {
    var clickedCode: ((String, CGRect) -> Void)?
    var clickedLink: ((URL) -> Void)?
    /// The string last given, to tell a redraw with the same text apart.
    var shown: NSAttributedString?
    private var downAt: NSPoint?

    /// Lays the text out at the width it's drawn at. Sizing sets the
    /// width too, but the last size asked for can be an ideal one with no
    /// width (10,000 points), and then the text drew as one long line.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if let container = textContainer, newSize.width >= 1, container.size.width != newSize.width {
            container.size = NSSize(width: newSize.width, height: .greatestFiniteMagnitude)
        }
    }

    override func mouseDown(with event: NSEvent) {
        downAt = event.locationInWindow
        let point = convert(event.locationInWindow, from: nil)
        if let (code, rect) = code(at: point) {
            // A click on code copies it; anything more (a drag, a double
            // click) selects as usual.
            if event.clickCount == 1, let window, let up = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
                if up.type == .leftMouseUp {
                    clickedCode?(code, rect)
                    return
                }
                window.postEvent(up, atStart: true)
            }
        }
        super.mouseDown(with: event)
    }

    override func copy(_ sender: Any?) {
        _ = writeSelection(to: .general, types: [.html, .string])
    }

    /// Copying and dragging a selection both come through here.
    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard let storage = textStorage, selectedRange().length > 0 else { return false }
        let copied = ProseCopy.copied(in: storage, range: selectedRange())
        if copied.isMarkdown {
            MarkdownExport.copy(copied.text, to: pboard)
        } else {
            pboard.clearContents()
            pboard.setString(copied.text, forType: .string)
        }
        return true
    }

    override func clicked(onLink link: Any, at charIndex: Int) {
        if let url = link as? URL { clickedLink?(url) }
        else if let string = link as? String, let url = URL(string: string) { clickedLink?(url) }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage else { return }
        storage.enumerateAttribute(.benchCode, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value != nil else { return }
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layout.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                           in: container) { rect, _ in
                self.addCursorRect(rect, cursor: .pointingHand)
            }
        }
    }

    /// The code span under a point and its rect, in this view's space.
    private func code(at point: NSPoint) -> (String, CGRect)? {
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        var fraction: CGFloat = 0
        let glyph = layout.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: &fraction)
        let glyphRect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard glyphRect.insetBy(dx: -3, dy: 0).contains(point) else { return nil }
        let index = layout.characterIndexForGlyph(at: glyph)
        var range = NSRange()
        guard index < storage.length,
              let code = storage.attribute(.benchCode, at: index, longestEffectiveRange: &range,
                                           in: NSRange(location: 0, length: storage.length)) as? String else { return nil }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = CGRect.null
        layout.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                       in: container) { piece, _ in
            if piece.insetBy(dx: -3, dy: 0).contains(point) { rect = piece }
        }
        return (code, rect.isNull ? glyphRect : rect)
    }
}

/// Draws the rounded chip behind each code span, as the SwiftUI lines do.
private final class ChipLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(.benchCode, in: characters) { value, range, _ in
            guard value != nil, let color = storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor else { return }
            color.withAlphaComponent(0.1).setFill()
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                    in: container) { rect, _ in
                let chip = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -3, dy: 0)
                NSBezierPath(roundedRect: chip, xRadius: 4, yRadius: 4).fill()
            }
        }
    }
}
#endif
