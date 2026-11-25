import AppKit
import BenchKit
import SwiftUI
@preconcurrency import CodeEditLanguages
@preconcurrency import SwiftTreeSitter

/// Colored code for the file and diff views. tree-sitter parses the text
/// with the grammar for the file's language, and its highlight queries say
/// what each piece is: a keyword, a string, a comment. The colors come
/// from the terminal theme, so code here looks like code in the terminal.
enum SyntaxColors {
    enum Kind: Sendable {
        case keyword, string, comment, number, function, type, tag, builtin

        /// The same kind, as the phone hears it.
        nonisolated var code: CodeKind {
            switch self {
            case .keyword: .keyword
            case .string: .string
            case .comment: .comment
            case .number: .number
            case .function: .function
            case .type: .type
            case .tag: .tag
            case .builtin: .builtin
            }
        }
    }

    struct Span: Sendable, Equatable {
        var range: NSRange
        var kind: Kind
    }

    /// Bigger files stay plain: parsing them would take too long to be worth it.
    nonisolated static let maxLength = 1_000_000

    // MARK: Finding spans (off the main thread)

    /// Grammars and queries aren't safe to use from two threads at once.
    nonisolated private static let queue = DispatchQueue(label: "Workbench.syntax", qos: .userInitiated)

    /// The spans to color in a file's text, or nil for a language without a
    /// grammar here, or text too big to parse.
    static func spans(in text: String, path: String) async -> [Span]? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: parse(text, path: path)) }
        }
    }

    /// The same for a diff. The old and new versions are parsed apart, so
    /// each reads as real code: context and added lines are the new file,
    /// context and removed lines the old one. Context lines take the new
    /// file's colors.
    static func spans(in layout: DiffLayout, path: String) async -> [Span]? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: parseDiff(layout, path: path)) }
        }
    }

    /// One file's lines in a diff of several files, as the Review view shows.
    struct Section: Sendable, Equatable {
        var lines: Range<Int>
        var path: String
    }

    /// The same for a diff of several files, each colored in its own
    /// language. Nil when none of them has a grammar here.
    static func spans(in layout: DiffLayout, sections: [Section]) async -> [Span]? {
        await withCheckedContinuation { continuation in
            queue.async {
                let found = sections.compactMap { parseDiff(layout, path: $0.path, lines: $0.lines) }
                continuation.resume(returning: found.isEmpty ? nil : found.flatMap { $0 })
            }
        }
    }

    /// Spans as runs for a client, over a file's text.
    static func runs(in text: String, path: String) async -> [CodeRun]? {
        await spans(in: text, path: path)?.map { CodeRun(start: $0.range.location, length: $0.range.length, kind: $0.kind.code) }
    }

    /// A diff's lines with what to color in each, for a client. Lines come
    /// back unchanged for a language with no grammar here.
    static func colored(_ lines: [DiffLine], path: String) async -> [DiffLine] {
        let layout = DiffLayout(lines: lines)
        guard let spans = await spans(in: layout, path: path) else { return lines }
        let runs = layout.runsByLine(spans.map { CodeRun(start: $0.range.location, length: $0.range.length, kind: $0.kind.code) })
        var result = lines
        for index in result.indices where !runs[index].isEmpty { result[index].code = runs[index] }
        return result
    }

    nonisolated private static func parse(_ text: String, path: String) -> [Span]? {
        let length = (text as NSString).length
        guard length > 0, length <= maxLength else { return nil }
        let language = CodeLanguage.detectLanguageFrom(url: URL(fileURLWithPath: path), prefixBuffer: String(text.prefix(256)))
        guard language.id != .plainText, let grammar = language.language,
              let query = highlightQuery(for: language, grammar: grammar) else { return nil }
        let parser = Parser()
        guard (try? parser.setLanguage(grammar)) != nil, let tree = parser.parse(text) else { return nil }
        return query.execute(in: tree)
            .resolve(with: .init(string: text))
            .highlights()
            .compactMap { highlight in kind(for: highlight.name).map { Span(range: highlight.range, kind: $0) } }
    }

    /// Highlight queries by language, built once. Only touched on `queue`.
    nonisolated(unsafe) private static var queries: [TreeSitterLanguage: Query?] = [:]

    /// The language's highlight query: its highlights.scm, plus its parent
    /// language's (TypeScript builds on JavaScript) and any extra highlight
    /// files (JSX). CodeEdit's own loader also mixes in the folds, indents
    /// and tags files, which don't compile as highlights, so it's not used.
    nonisolated private static func highlightQuery(for language: CodeLanguage, grammar: Language) -> Query? {
        if let cached = queries[language.id] { return cached }
        var urls: [URL] = []
        if let url = language.queryURL {
            urls.append(url)
            let folder = url.deletingLastPathComponent()
            for name in (language.additionalHighlights ?? []) where name.hasPrefix("highlights") {
                urls.append(folder.appendingPathComponent("\(name).scm"))
            }
        }
        if let parent = language.parentQueryURL { urls.append(parent) }
        let source = urls.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
        let query = source.isEmpty ? nil : try? Query(language: grammar, data: Data(source.utf8))
        queries[language.id] = query
        return query
    }

    /// `lines` keeps it to part of the diff: one file's lines out of several.
    nonisolated private static func parseDiff(_ layout: DiffLayout, path: String, lines: Range<Int>? = nil) -> [Span]? {
        let source = layout.text as NSString
        // One side of the diff as its own text, with where each of its
        // lines came from in the diff.
        struct Side {
            var text = ""
            var lines: [(diff: NSRange, offset: Int, keep: Bool)] = []
        }
        var new = Side(), old = Side()
        for (index, range) in layout.ranges.enumerated() where lines?.contains(index) ?? true {
            let kind = layout.kinds[index]
            let line = source.substring(with: range)
            if kind == .context || kind == .added {
                new.lines.append((range, (new.text as NSString).length, true))
                new.text += line + "\n"
            }
            if kind == .context || kind == .removed {
                old.lines.append((range, (old.text as NSString).length, kind == .removed))
                old.text += line + "\n"
            }
        }
        var result: [Span] = []
        var known = false
        for side in [new, old] where !side.lines.isEmpty {
            guard let spans = parse(side.text, path: path) else { continue }
            known = true
            // Each span, cut at line ends and moved to its place in the diff.
            for span in spans {
                for line in side.lines where line.keep {
                    let start = max(span.range.location, line.offset)
                    let end = min(NSMaxRange(span.range), line.offset + line.diff.length)
                    guard end > start else { continue }
                    result.append(Span(range: NSRange(location: line.diff.location + start - line.offset, length: end - start),
                                       kind: span.kind))
                }
            }
        }
        return known ? result : nil
    }

    /// What a highlight query's capture name ("keyword.function",
    /// "string.special") is, for coloring. Names that aren't worth a color,
    /// like variables and punctuation, stay in the text color.
    nonisolated static func kind(for name: String) -> Kind? {
        let head = name.split(separator: ".").first.map(String.init) ?? name
        switch head {
        case "keyword", "include", "conditional", "repeat", "exception", "storageclass":
            return .keyword
        case "string", "character", "escape":
            return .string
        case "comment":
            return .comment
        case "number", "float", "boolean":
            return .number
        case "function", "method":
            return name.contains("builtin") ? .builtin : .function
        case "type", "constructor", "namespace", "module":
            return .type
        case "tag":
            return .tag
        case "constant":
            return name.contains("builtin") ? .number : nil
        case "variable":
            return name.contains("builtin") ? .builtin : nil
        default:
            return nil
        }
    }

    // MARK: Colors (main thread)

    /// The color for each kind: the terminal theme's ANSI colors when the
    /// app matches the theme, made readable on its background, or colors
    /// that work in the system's light and dark otherwise.
    static func color(for kind: Kind) -> NSColor {
        let theme = TerminalTheme.shared
        switch kind {
        case .keyword: return theme.readableThemeColor(.magenta, contrast: 3.5)
        case .string: return theme.readableThemeColor(.green, contrast: 3.5)
        case .comment: return .secondaryLabelColor
        case .number: return theme.readableThemeColor(.yellow, contrast: 3.5)
        case .function: return theme.readableThemeColor(.blue, contrast: 3.5)
        case .type: return theme.readableThemeColor(.cyan, contrast: 3.5)
        case .tag: return theme.readableThemeColor(.red, contrast: 3.5)
        case .builtin: return theme.readableThemeColor(.red, contrast: 3.5)
        }
    }
}

extension CodeTextContainer {
    /// Colors the text with `spans`, if it's still `text`; plain parts get
    /// `base`. Lines the caller colored itself, like a diff's hunk headers,
    /// are left alone since no span touches them.
    /// `resetting` first puts everything back to plain, for text that's
    /// edited and colored again.
    func applySyntax(_ spans: [SyntaxColors.Span], to text: String, resetting: Bool = false) {
        guard let storage = textView.textStorage, storage.string == text else { return }
        var colors: [SyntaxColors.Kind: NSColor] = [:]
        storage.beginEditing()
        if resetting {
            storage.addAttribute(.foregroundColor, value: textView.textColor ?? .textColor,
                                 range: NSRange(location: 0, length: storage.length))
        }
        for span in spans where NSMaxRange(span.range) <= storage.length {
            let color = colors[span.kind] ?? SyntaxColors.color(for: span.kind)
            colors[span.kind] = color
            storage.addAttribute(.foregroundColor, value: color, range: span.range)
        }
        storage.endEditing()
    }
}

#if DEBUG
/// A file drawn to PNGs in light and dark with its code colored.
/// BENCH_RENDER_CODE=<folder>, BENCH_RENDER_CODE_FILE=<file to draw>.
enum SyntaxColorsPreview {
    static func render(to folder: URL, file: URL) {
        _ = NSApplication.shared
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let size = NSSize(width: 900, height: 700)
            let env = ProcessInfo.processInfo.environment
            let marks = env["BENCH_RENDER_CODE_MARKS"].flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
                .map(ChangeMark.marks(fromZeroContextDiff:)) ?? [:]
            let code = CodeTextView(text: text, wraps: false, path: file.path, marks: marks, jump: ChangeJump(id: marks.isEmpty ? 0 : 1))
            let host = NSHostingView(rootView: VStack(spacing: 0) {
                code.frame(height: size.height / 2)
                diff(path: file.path).frame(height: size.height / 2)
            }.frame(width: size.width, height: size.height))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            host.setFrameSize(size)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(2))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            let name = file.deletingPathExtension().lastPathComponent + "-" + file.pathExtension
            try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("\(name)-\(mode).png"))
        }
    }

    /// A small Swift diff: a hunk header, context, a removed and an added line.
    /// BENCH_RENDER_CODE_REVIEW=<file of `git show` output> draws that as
    /// the Review view does, each file colored in its own language.
    @ViewBuilder private static func diff(path: String) -> some View {
        if let review = ProcessInfo.processInfo.environment["BENCH_RENDER_CODE_REVIEW"],
           let text = try? String(contentsOfFile: review, encoding: .utf8) {
            let diff = ReviewDiff(parsing: text)
            DiffTextView(layout: DiffLayout(lines: diff.lines), segments: diff.lines.map(\.segments),
                         oldNumbers: diff.lines.map(\.oldNumber), newNumbers: diff.lines.map(\.newNumber), wraps: false,
                         commentedLines: [], composing: nil, headers: Set(diff.files.map(\.headerLine)),
                         sections: diff.files.indices.map {
                             SyntaxColors.Section(lines: diff.lineRange(ofFileAt: $0), path: diff.files[$0].path)
                         }) { _ in }
        } else {
            singleDiff(path: path)
        }
    }

    private static func singleDiff(path: String) -> some View {
        if let full = ProcessInfo.processInfo.environment["BENCH_RENDER_CODE_DIFF"],
           let text = try? String(contentsOfFile: full, encoding: .utf8) {
            let result = DiffFolding.fold(DiffParser.parse(text), expanded: [])
            let lines = result.lines
            return DiffTextView(layout: DiffLayout(lines: lines), path: path, segments: lines.map(\.segments),
                                oldNumbers: lines.map(\.oldNumber), newNumbers: lines.map(\.newNumber), wraps: false,
                                commentedLines: [], composing: nil, folds: Set(result.folds.keys)) { _ in }
        }
        let rows: [(DiffLine.Kind, String)] = [
            (.hunk, "@@ -1,5 +1,5 @@"), (.context, "struct Lap {"), (.removed, "    let time: Double = 0"),
            (.added, "    var time: Double = 1.5 // seconds"), (.context, "    func label() -> String { \"lap\" }"), (.context, "}"),
        ]
        let lines = rows.enumerated().map { DiffLine(id: $0.offset, kind: $0.element.0, text: $0.element.1, oldNumber: $0.offset, newNumber: $0.offset) }
        return DiffTextView(layout: DiffLayout(lines: lines), path: "Lap.swift", segments: lines.map { _ in [] },
                            oldNumbers: lines.map(\.oldNumber), newNumbers: lines.map(\.newNumber), wraps: false,
                            commentedLines: [], composing: nil) { _ in }
    }
}
#endif
