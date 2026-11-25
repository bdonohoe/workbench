import SwiftUI

/// Claude's replies are Markdown. SwiftUI handles the inline parts (bold,
/// code, links); this adds the block parts it doesn't: code fences,
/// headings, nested lists, quotes, rules and real tables.
public struct MarkdownText: View {
    @Environment(\.companionPalette) private var palette
    @Environment(\.markdownFonts) private var fonts
    public let text: String
    /// Links and code take the color around them instead of their own,
    /// for text on a colored bubble.
    public let inheritsColor: Bool
    /// The color around the text, for `inheritsColor`. With it, a long
    /// message on the Mac draws as one text view rather than a SwiftUI
    /// Text per line, which a big paste has thousands of.
    public let ink: Color?

    public init(text: String, inheritsColor: Bool = false, ink: Color? = nil) {
        self.text = text
        self.inheritsColor = inheritsColor
        self.ink = ink
    }

    /// One text view for a colored bubble only pays off past this many
    /// bytes; shorter ones keep hugging their text.
    static let longInheritedText = 2_000

    #if DEBUG
    public static let sample = """
    ## Rename summary
    "Free play" is now **Endless** on the Solitaire page. It's running at http://localhost:3111, so reload to see it.

    | Where | Before | After |
    |---|---|---|
    | Section heading on the Solitaire page | Free play | Endless |
    | Table title and share picture | Free deal 12 | Endless deal 12 |
    | Copied share text | `free deal 12` | `Endless deal 12` |
    | Locked card back rule | 5 free deals won | 5 Endless deals won |

    Decide before merging:
    - **Plus gate:** Solitaire's Endless mode is free for everyone.
      - nonogram Endless needs Plus
      - the planned gate was never built
    - [ ] Check the iOS app's door
    - [x] Update the share text

    > The admin pages still say "free", since players never see them.

    1. Build passes
    2. Tests pass

    ---

    ```swift
    let mode = "Endless"
    ```
    """
    #endif

    public enum Block: Equatable {
        case paragraph(String)
        case heading(level: Int, String)
        case code(String)
        case bullet(level: Int, String)
        case numbered(level: Int, number: String, String)
        /// The quote's Markdown with its ">" markers taken off, so it can
        /// hold paragraphs, lists, and nested quotes.
        case quote(String)
        case rule
        case table(header: [String], rows: [[String]])
    }

    /// A block to draw on its own, or a run of prose drawn as one Mac text
    /// view so it can be selected across lines.
    private enum Segment {
        case block(Block)
        case prose([Block])
    }

    private var segments: [Segment] {
        let blocks = MarkdownCache.shared.blocks(in: text)
        #if os(macOS)
        let prose = fonts.prose != nil && (!inheritsColor || (ink != nil && text.utf8.count > Self.longInheritedText))
        guard prose else { return blocks.map { .block($0) } }
        var segments: [Segment] = []
        for block in blocks {
            switch block {
            case .paragraph, .heading, .bullet, .numbered:
                if case .prose(let run) = segments.last {
                    segments[segments.count - 1] = .prose(run + [block])
                } else {
                    segments.append(.prose([block]))
                }
            default:
                segments.append(.block(block))
            }
        }
        return segments
        #else
        return blocks.map { .block($0) }
        #endif
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .prose(let blocks):
                    #if os(macOS)
                    if let prose = fonts.prose { ProseText(blocks: blocks, fonts: prose, ink: inheritsColor ? ink : nil) }
                    #endif
                case .block(let block):
                    blockView(block)
                }
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder private func blockView(_ block: Block) -> some View {
                switch block {
                case .paragraph(let line):
                    inline(line)
                case .heading(let level, let line):
                    inline(line)
                        .font(fonts.heading(level: level))
                        .padding(.top, 4)
                case .code(let code):
                    CodeBlock(code: code)
                case .bullet(let level, let line):
                    HStack(alignment: .top, spacing: 6) {
                        Text(level == 0 ? "•" : "◦").foregroundStyle(.secondary)
                        inline(line)
                    }
                    .padding(.leading, 6 + CGFloat(level) * 16)
                case .numbered(let level, let number, let line):
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(number).").foregroundStyle(.secondary).monospacedDigit()
                        inline(line)
                    }
                    .padding(.leading, 6 + CGFloat(level) * 16)
                case .quote(let inner):
                    // AnyView, since a quote is Markdown inside Markdown.
                    AnyView(MarkdownText(text: inner, inheritsColor: inheritsColor))
                        .foregroundStyle(palette.ink.opacity(0.85))
                        .padding(.leading, 13)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // Drawn behind the text, so the bar is exactly as
                        // tall as the quote and never takes height from it.
                        .background(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 1.5).fill(palette.accent.opacity(0.6)).frame(width: 3)
                        }
                        .padding(.leading, 2)
                case .rule:
                    Rectangle().fill(palette.hairline).frame(height: 1).padding(.vertical, 4)
                case .table(let header, let rows):
                    MarkdownTable(header: header, rows: rows)
                }
    }

    private func inline(_ line: String) -> InlineMarkdown {
        InlineMarkdown(line: line, inheritsColor: inheritsColor)
    }

    /// Links get their own color, so you can see what's clickable.
    static func parseInline(_ line: String) -> AttributedString {
        var text = (try? AttributedString(markdown: escapingLoneTildes(line), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(line)
        for run in text.runs where run.link != nil {
            text[run.range].foregroundColor = StepColors.link
        }
        return text
    }

    /// Foundation's Markdown strikes through text between single tildes,
    /// so two home paths (`@~/a @~/b`) or two rough numbers (`~5 to ~10`)
    /// lose their tildes and get a line through them. Only `~~gone~~`
    /// strikes through here, as in Claude Code's own terminal. Code spans,
    /// `<autolinks>`, web addresses and characters already escaped are left
    /// as they are, since a backslash there would show (and in an address,
    /// end up in the link).
    static func escapingLoneTildes(_ line: String) -> String {
        guard line.contains("~") else { return line }
        let chars = Array(line)
        var result = ""
        var index = 0
        while index < chars.count {
            let char = chars[index]
            switch char {
            case "\\":
                result.append(char)
                if index + 1 < chars.count { result.append(chars[index + 1]) }
                index += 2
            case "`":
                var run = 0
                while index + run < chars.count, chars[index + run] == "`" { run += 1 }
                // The span ends at the next run of exactly as many backticks.
                var end: Int?
                var look = index + run
                while look < chars.count {
                    if chars[look] == "`" {
                        var other = 0
                        while look + other < chars.count, chars[look + other] == "`" { other += 1 }
                        if other == run { end = look + other; break }
                        look += other
                    } else {
                        look += 1
                    }
                }
                let stop = end ?? index + run
                result.append(contentsOf: chars[index..<stop])
                index = stop
            case "<":
                var look = index + 1
                while look < chars.count, chars[look] != ">", !chars[look].isWhitespace, chars[look] != "<" { look += 1 }
                if look < chars.count, chars[look] == ">" {
                    result.append(contentsOf: chars[index...look])
                    index = look + 1
                } else {
                    result.append(char)
                    index += 1
                }
            case "~":
                let paired = (index > 0 && chars[index - 1] == "~") || (index + 1 < chars.count && chars[index + 1] == "~")
                result += paired || isInWebAddress(chars, at: index) ? "~" : "\\~"
                index += 1
            default:
                result.append(char)
                index += 1
            }
        }
        return result
    }

    /// Whether the character at `index` is part of a web address written
    /// out bare (`https://example.com/~me`), which Markdown links as it is.
    private static func isInWebAddress(_ chars: [Character], at index: Int) -> Bool {
        var start = index
        while start > 0, !chars[start - 1].isWhitespace { start -= 1 }
        let before = String(chars[start..<index]).lowercased()
        // A loop, not a closure: a closure here is tied to the main actor,
        // and this runs wherever the text is parsed.
        for start in ["http://", "https://", "ftp://", "www."] where before.contains(start) { return true }
        return false
    }

    /// Where the links are, in UTF-16 offsets, which is how a text layout
    /// counts its characters.
    static func linkRanges(in text: AttributedString) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        for run in text.runs {
            let end = start + text.utf16Length(of: run)
            if run.link != nil { ranges.append(start..<end) }
            start = end
        }
        return ranges
    }

    // MARK: Parsing

    public static func blocks(in text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        var table: [[String]] = []
        var quote: [String]?

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        func flushTable() {
            if let header = table.first {
                let width = header.count
                let rows = table.dropFirst().map { row in
                    row.count >= width ? Array(row.prefix(width)) : row + Array(repeating: "", count: width - row.count)
                }
                blocks.append(.table(header: header, rows: Array(rows)))
            }
            table = []
        }
        func flushQuote() {
            if let lines = quote {
                let inner = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
                if !inner.isEmpty { blocks.append(.quote(inner)) }
            }
            quote = nil
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if var open = code {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    blocks.append(.code(open.joined(separator: "\n")))
                    code = nil
                } else {
                    open.append(line)
                    code = open
                }
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Consecutive ">" lines are one quote, blank ">" lines and all.
            if trimmed.hasPrefix(">") {
                flushParagraph(); flushTable()
                var content = trimmed.dropFirst()
                if content.first == " " { content = content.dropFirst() }
                quote = (quote ?? []) + [String(content)]
                continue
            }
            flushQuote()
            let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            let level = min(indent / 2, 3)

            if trimmed.hasPrefix("```") {
                flushParagraph(); flushTable()
                code = []
            } else if trimmed.hasPrefix("|"), trimmed.count > 1 {
                flushParagraph()
                if isTableSeparator(trimmed) { continue }
                table.append(tableCells(trimmed))
            } else if trimmed.isEmpty {
                flushParagraph(); flushTable()
            } else if isRule(trimmed) {
                flushParagraph(); flushTable()
                blocks.append(.rule)
            } else if trimmed.hasPrefix("#") {
                flushParagraph(); flushTable()
                let hashes = trimmed.prefix(while: { $0 == "#" }).count
                blocks.append(.heading(level: min(hashes, 3), trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces)))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") || trimmed.hasPrefix("• ") {
                flushParagraph(); flushTable()
                blocks.append(.bullet(level: level, checkbox(String(trimmed.dropFirst(2)))))
            } else if let dot = trimmed.firstIndex(where: { $0 == "." || $0 == ")" }), !trimmed[..<dot].isEmpty,
                      trimmed[..<dot].allSatisfy(\.isNumber), trimmed[trimmed.index(after: dot)...].hasPrefix(" ") {
                flushParagraph(); flushTable()
                blocks.append(.numbered(level: level, number: String(trimmed[..<dot]),
                                        trimmed[trimmed.index(after: dot)...].trimmingCharacters(in: .whitespaces)))
            } else {
                flushTable()
                paragraph.append(trimmed)
            }
        }
        if let code { blocks.append(.code(code.joined(separator: "\n"))) }
        flushParagraph(); flushTable(); flushQuote()
        return blocks
    }

    /// "- [ ] thing" and "- [x] thing" as checkbox glyphs.
    private static func checkbox(_ text: String) -> String {
        if text.hasPrefix("[ ] ") { return "☐ " + text.dropFirst(4) }
        if text.lowercased().hasPrefix("[x] ") { return "☑ " + text.dropFirst(4) }
        return text
    }

    private static func isRule(_ line: String) -> Bool {
        let bare = line.replacingOccurrences(of: " ", with: "")
        guard bare.count >= 3 else { return false }
        return bare.allSatisfy { $0 == "-" } || bare.allSatisfy { $0 == "*" } || bare.allSatisfy { $0 == "_" }
    }

    /// The "|---|:---:|" row under a table's header.
    private static func isTableSeparator(_ line: String) -> Bool {
        let inner = line.trimmingCharacters(in: CharacterSet(charactersIn: "|")).replacingOccurrences(of: " ", with: "")
        guard inner.contains("-") else { return false }
        return inner.allSatisfy { "-:|".contains($0) }
    }

    /// A table written back out as Markdown, with its columns padded to
    /// line up so it reads well as plain text too. Pipes in a cell are
    /// escaped, and short rows get empty cells.
    public static func tableMarkdown(header: [String], rows: [[String]]) -> String {
        let count = max(header.count, rows.map(\.count).max() ?? 0)
        func cells(_ row: [String]) -> [String] {
            (0..<count).map { $0 < row.count ? row[$0].replacingOccurrences(of: "|", with: "\\|") : "" }
        }
        let all = [cells(header)] + rows.map(cells)
        let widths = (0..<count).map { column in max(3, all.map { $0[column].count }.max() ?? 0) }
        func line(_ row: [String]) -> String {
            "| " + row.enumerated().map { $1.padding(toLength: widths[$0], withPad: " ", startingAt: 0) }.joined(separator: " | ") + " |"
        }
        let rule = "| " + widths.map { String(repeating: "-", count: $0) }.joined(separator: " | ") + " |"
        return ([line(all[0]), rule] + all.dropFirst().map(line)).joined(separator: "\n")
    }

    /// Splits a "| a | b |" row into cells, honoring escaped pipes.
    public static func tableCells(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var escaped = false
        var inCode = false
        for char in line {
            if escaped {
                current.append(char)
                escaped = false
            } else if char == "\\" {
                escaped = true
            } else if char == "`" {
                inCode.toggle()
                current.append(char)
            } else if char == "|", !inCode {
                cells.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        cells.append(current)
        // The row starts and ends with a pipe, so the outer cells are empty.
        if cells.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeFirst() }
        if cells.last?.trimmingCharacters(in: .whitespaces).isEmpty == true, cells.count > 1 { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

/// A fenced code block, with a copy button in its corner. On the Mac the
/// button shows while the pointer is over the block; on iPhone it's always there.
private struct CodeBlock: View {
    @Environment(\.companionPalette) private var palette
    @Environment(\.markdownFonts) private var fonts
    let code: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code)
                .font(fonts.code)
                // Always its full size, so the block scrolls sideways. On the
                // Mac a long first line could otherwise squeeze the block to
                // one line, cut off with "…", hiding the lines below it.
                .fixedSize()
                .padding(10)
                // Room at the end of the longest line, so it can scroll out from under the button.
                .padding(.trailing, 26)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(palette.hairline))
        .copyButton(label: "Copy code") { code }
    }
}

/// A copy button in a block's top corner. On the Mac it shows while the
/// pointer is over the block; on iPhone it's always there.
private struct CopyCorner: ViewModifier {
    @Environment(\.companionPalette) private var palette
    let label: String
    let text: () -> String
    #if os(macOS)
    @State private var hovering = false
    #else
    private let hovering = true
    #endif
    @State private var copied = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                if hovering || copied {
                    Button(action: copy) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .medium))
                            .contentTransition(.symbolEffect(.replace))
                            .foregroundStyle(copied ? palette.accent : palette.inkMuted)
                            .frame(width: 24, height: 24)
                            .background(palette.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(palette.hairline))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                    .help(copied ? "Copied" : label)
                    .accessibilityLabel(label)
                    .padding(6)
                    .transition(.opacity)
                }
            }
            #if os(macOS)
            .onHover { hovering = $0 }
            #endif
            .animation(.easeOut(duration: 0.15), value: hovering)
            .animation(.easeOut(duration: 0.15), value: copied)
    }

    private func copy() {
        let string = text()
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #else
        UIPasteboard.general.string = string
        #endif
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            copied = false
        }
    }
}

private extension View {
    func copyButton(label: String, text: @escaping () -> String) -> some View {
        modifier(CopyCorner(label: label, text: text))
    }
}

/// A line of bold, code, and links. `Inline code` gets the palette's code
/// color on a rounded chip. A click (or tap) copies it, since the point of
/// a name or command in a reply is nearly always to paste it somewhere,
/// except on a Mac when it's a path to a file: that shows it in the Finder.
private struct InlineMarkdown: View {
    @Environment(\.markdownFonts) private var fonts
    @Environment(\.companionPalette) private var palette
    let line: String
    var inheritsColor = false

    var body: some View {
        if inheritsColor {
            Text(uncolored)
        } else if styled.links.isEmpty && styled.code.isEmpty {
            Text(styled.text)
        } else {
            Text(styled.text).modifier(InlineTargets(links: styled.links, code: styled.code))
        }
    }

    private var styled: InlineStyle {
        InlineStyle(MarkdownCache.shared.inline(line), codeFont: fonts.inlineCode, codeColor: palette.code)
    }

    /// The line with its link color taken off, so it takes the color around it.
    private var uncolored: AttributedString {
        var text = MarkdownCache.shared.inline(line)
        text.foregroundColor = nil
        return text
    }
}

/// One `code` span: where it is in the line (UTF-16 offsets, which is how a
/// text layout counts) and the text to copy.
struct CodeSpan: Equatable {
    var range: Range<Int>
    var text: String
}

extension AttributedString {
    /// How many UTF-16 units a run of this text takes. Runs come in order
    /// and cover the whole text, so adding these up gives each run's
    /// offset. (`utf16` would say directly, but needs macOS 26.)
    fileprivate func utf16Length(of run: Runs.Run) -> Int {
        String(self[run.range].characters).utf16.count
    }
}

/// A parsed line with its code styled and made clickable.
struct InlineStyle {
    /// Code spans are links to this scheme, with their index as the host,
    /// so a click comes back through `openURL` instead of a browser.
    static let copyScheme = "bench-copy"

    var text: AttributedString
    var links: [Range<Int>] = []
    var code: [CodeSpan] = []

    init(_ parsed: AttributedString, codeFont: Font?, codeColor: Color) {
        text = parsed
        var start = 0
        for run in parsed.runs {
            let range = start..<(start + parsed.utf16Length(of: run))
            start = range.upperBound
            if run.link != nil {
                links.append(range)
            } else if run.inlinePresentationIntent?.contains(.code) == true {
                if let codeFont { text[run.range].font = codeFont }
                text[run.range].foregroundColor = codeColor
                text[run.range].link = URL(string: "\(Self.copyScheme)://\(code.count)")
                code.append(CodeSpan(range: range, text: String(parsed[run.range].characters)))
            }
        }
    }
}

/// Draws the chips behind a line's code, copies one when it's clicked and
/// says so (or shows the file it names, where that's set up), and on the
/// Mac shows the pointing hand over code and links.
/// SwiftUI can't say where part of a Text is, so this reads its layout,
/// including each piece of a span that wraps.
private struct InlineTargets: ViewModifier {
    @Environment(\.companionPalette) private var palette
    @Environment(\.revealStepFile) private var revealFile
    /// The app's own link handling, for links that aren't code spans.
    @Environment(\.openURL) private var openElsewhere
    let links: [Range<Int>]
    let code: [CodeSpan]

    private struct Area: Equatable {
        /// The code span's index, or nil for a link.
        var code: Int?
        var rect: CGRect
    }

    @State private var areas: [Area] = []
    @State private var hovered: Int?
    @State private var copied: Int?
    #if os(macOS)
    @State private var showsHand = false
    #endif

    func body(content: Content) -> some View {
        content
            .backgroundPreferenceValue(Text.LayoutKey.self) { layouts in
                GeometryReader { geometry in
                    let found = layouts.flatMap { anchored in
                        targets(in: anchored.layout, at: geometry[anchored.origin])
                    }
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(found.enumerated()), id: \.offset) { _, area in
                            if let index = area.code {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(palette.code.opacity(index == hovered || index == copied ? 0.2 : 0.1))
                                    .frame(width: area.rect.width + 6, height: area.rect.height)
                                    .offset(x: area.rect.minX - 3, y: area.rect.minY)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .onChange(of: found, initial: true) { _, new in areas = new }
                }
            }
            .overlay {
                // Centered just above the span. The overlay is the line's
                // own frame, the space the span's position is measured in.
                if let copied, let area = areas.first(where: { $0.code == copied }) {
                    CopiedBubble()
                        .fixedSize()
                        .position(x: area.rect.midX, y: area.rect.minY - CopiedBubble.height / 2 - 3)
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.15), value: copied)
            .animation(.easeOut(duration: 0.1), value: hovered)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == InlineStyle.copyScheme else {
                    openElsewhere(url)
                    return .handled
                }
                if let index = url.host().flatMap(Int.init), code.indices.contains(index) {
                    if revealFile?(code[index].text) != true { copy(index) }
                }
                return .handled
            })
            #if os(iOS)
            .sensoryFeedback(.success, trigger: copied) { _, new in new != nil }
            #endif
            #if os(macOS)
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    let area = areas.first { $0.rect.insetBy(dx: -3, dy: 0).contains(point) }
                    hovered = area?.code
                    showsHand = area != nil
                    (showsHand ? NSCursor.pointingHand : NSCursor.iBeam).set()
                case .ended:
                    // Nothing else puts the arrow back after the hand.
                    if showsHand { NSCursor.arrow.set() }
                    showsHand = false
                    hovered = nil
                }
            }
            #endif
    }

    private func copy(_ index: Int) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code[index].text, forType: .string)
        #else
        UIPasteboard.general.string = code[index].text
        #endif
        copied = index
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            if copied == index { copied = nil }
        }
    }

    private func targets(in layout: Text.Layout, at origin: CGPoint) -> [Area] {
        // Indices only say how far apart they are, so count from the first.
        guard let start = layout.first?.first?.characterIndices.first else { return [] }
        var found: [Area] = []
        for line in layout {
            for run in line {
                guard let first = run.characterIndices.first else { continue }
                let offset = start.distance(to: first)
                let rect = run.typographicBounds.rect.offsetBy(dx: origin.x, dy: origin.y)
                if let index = code.firstIndex(where: { $0.range.contains(offset) }) {
                    found.append(Area(code: index, rect: rect))
                } else if links.contains(where: { $0.contains(offset) }) {
                    found.append(Area(code: nil, rect: rect))
                }
            }
        }
        return found
    }
}

/// "Copied", shown over a code span for a moment after it's clicked.
struct CopiedBubble: View {
    @Environment(\.companionPalette) private var palette
    static let height: CGFloat = 20

    var body: some View {
        Label("Copied", systemImage: "checkmark")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(palette.ink)
            .padding(.horizontal, 7)
            .frame(height: Self.height)
            #if os(macOS)
            .benchGlass(in: Capsule())
            #else
            .background(Capsule().fill(palette.surface).shadow(color: .black.opacity(0.12), radius: 3, y: 1))
            .overlay(Capsule().strokeBorder(palette.hairline))
            #endif
    }
}

/// Parsed Markdown, kept so a reply is parsed once rather than every time
/// the conversation draws. A message's text never changes once written,
/// so the text itself is the key.
@MainActor
public final class MarkdownCache {
    public static let shared = MarkdownCache()

    private final class Blocks {
        let blocks: [MarkdownText.Block]
        init(_ blocks: [MarkdownText.Block]) { self.blocks = blocks }
    }

    private final class Inline {
        let text: AttributedString
        init(_ text: AttributedString) { self.text = text }
    }

    private let blocks = NSCache<NSString, Blocks>()
    private let inlines = NSCache<NSString, Inline>()

    private init() {
        blocks.countLimit = 600
        inlines.countLimit = 6000
    }

    public func blocks(in text: String) -> [MarkdownText.Block] {
        let key = text as NSString
        if let cached = blocks.object(forKey: key) { return cached.blocks }
        let parsed = MarkdownText.blocks(in: text)
        blocks.setObject(Blocks(parsed), forKey: key)
        return parsed
    }

    public func inline(_ line: String) -> AttributedString {
        let key = line as NSString
        if let cached = inlines.object(forKey: key) { return cached.text }
        let parsed = MarkdownText.parseInline(line)
        inlines.setObject(Inline(parsed), forKey: key)
        return parsed
    }
}

/// A Markdown table: header row, hairlines between rows, and columns
/// sized like Claude Code's terminal tables. Short columns keep their
/// width, long ones wrap, and the last takes what's left. It only
/// scrolls sideways when there are more columns than can fit.
private struct MarkdownTable: View {
    @Environment(\.companionPalette) private var palette
    @Environment(\.markdownFonts) private var fonts
    let header: [String]
    let rows: [[String]]
    @State private var width: CGFloat?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            TableLayout(columns: header.count, available: width.map { $0 - 24 }) {
                ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                    InlineMarkdown(line: cell)
                        .font(fonts.tableHeader)
                        .foregroundStyle(palette.inkMuted)
                        .padding(.vertical, 7)
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        InlineMarkdown(line: cell)
                            .font(fonts.table)
                            .padding(.vertical, 7)
                    }
                }
                // One line under each row but the last; the header's is stronger.
                ForEach(0..<rows.count, id: \.self) { index in
                    Rectangle().fill(index == 0 ? palette.hairline : palette.hairline.opacity(0.6))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 2)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background(palette.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(palette.hairline))
        .copyButton(label: "Copy table") { MarkdownText.tableMarkdown(header: header, rows: rows) }
    }
}

/// Lays out a table's cells in rows, then its row lines. Its subviews are
/// the cells, row by row, followed by one line for under each row but the
/// last. `available` is the width to fit in, since the scroll view around
/// it doesn't say.
private struct TableLayout: Layout {
    let columns: Int
    let available: CGFloat?
    var spacing: CGFloat = 16
    /// How narrow a long column can get before the table scrolls instead.
    var narrowest: CGFloat = 110

    private struct Sizes {
        var widths: [CGFloat]
        var heights: [CGFloat]
        var width: CGFloat
    }

    private func sizes(width proposed: CGFloat?, subviews: Subviews) -> Sizes {
        guard columns > 0 else { return Sizes(widths: [], heights: [], width: 0) }
        let rowCount = subviews.count / (columns + 1) + (subviews.count % (columns + 1) > 0 ? 1 : 0)
        let cellCount = min(rowCount * columns, subviews.count)
        let rows = cellCount / columns
        var ideal = Array(repeating: CGFloat(0), count: columns)
        for index in 0..<(rows * columns) {
            ideal[index % columns] = max(ideal[index % columns], subviews[index].sizeThatFits(.unspecified).width)
        }
        let gaps = spacing * CGFloat(columns - 1)
        let room = (proposed ?? available).map { $0 - gaps }
        var widths = ideal
        if let room, room.isFinite, room > 0 {
            if ideal.reduce(0, +) <= room {
                // Everything fits; the last column runs to the edge.
                widths[columns - 1] += room - ideal.reduce(0, +)
            } else {
                // Cap the widest columns at the same width, as wide as fits.
                let floors = ideal.map { min($0, narrowest) }
                if floors.reduce(0, +) >= room {
                    widths = floors
                } else {
                    var low: CGFloat = 0, high = ideal.max() ?? 0
                    for _ in 0..<30 {
                        let cap = (low + high) / 2
                        let total = zip(ideal, floors).map { min($0, max(cap, $1)) }.reduce(0, +)
                        if total > room { high = cap } else { low = cap }
                    }
                    widths = zip(ideal, floors).map { min($0, max(low, $1)) }
                    widths[columns - 1] += max(0, room - widths.reduce(0, +))
                }
            }
        } else {
            // Unknown width: keep cells to a readable line length.
            widths = ideal.map { min($0, 320) }
        }
        var heights: [CGFloat] = []
        for row in 0..<rows {
            var height: CGFloat = 0
            for column in 0..<columns {
                let size = subviews[row * columns + column].sizeThatFits(ProposedViewSize(width: widths[column], height: nil))
                height = max(height, size.height)
            }
            heights.append(height)
        }
        return Sizes(widths: widths, heights: heights, width: widths.reduce(0, +) + gaps)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = sizes(width: proposal.width, subviews: subviews)
        let lines = CGFloat(max(sizes.heights.count - 1, 0))
        return CGSize(width: sizes.width, height: sizes.heights.reduce(0, +) + lines)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = sizes(width: bounds.width, subviews: subviews)
        let cells = sizes.heights.count * columns
        var y = bounds.minY
        for (row, height) in sizes.heights.enumerated() {
            var x = bounds.minX
            for column in 0..<columns {
                subviews[row * columns + column].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                                       proposal: ProposedViewSize(width: sizes.widths[column], height: height))
                x += sizes.widths[column] + spacing
            }
            y += height
            let line = cells + row
            if row < sizes.heights.count - 1, line < subviews.count {
                subviews[line].place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                                     proposal: ProposedViewSize(width: bounds.width, height: 1))
                y += 1
            }
        }
        // Anything left over (there shouldn't be) goes out of sight.
        for index in (cells + max(sizes.heights.count - 1, 0))..<subviews.count where index >= cells {
            subviews[index].place(at: CGPoint(x: bounds.minX, y: bounds.minY), proposal: .zero)
        }
    }
}
