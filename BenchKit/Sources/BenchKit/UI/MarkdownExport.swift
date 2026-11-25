import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Markdown as HTML for the clipboard, so a reply pasted into Mail, Notes,
/// Slack or a document keeps its headings, lists, tables and links. It
/// carries no fonts or colors: the text takes on the look of wherever it
/// lands, rather than the chat's (white ink, in dark mode).
@MainActor
public enum MarkdownExport {
    public static func html(_ markdown: String) -> String {
        html(MarkdownText.blocks(in: markdown))
    }

    static func html(_ blocks: [MarkdownText.Block]) -> String {
        // A lone paragraph is a phrase from a line, not a block of its own.
        if blocks.count == 1, case .paragraph(let line) = blocks[0] { return inline(line) }
        var out: [String] = []
        var list: [ListItem] = []
        func flushList() {
            if !list.isEmpty { out.append(listHTML(list)) }
            list = []
        }
        for block in blocks {
            switch block {
            case .bullet(let level, let line):
                list.append(ListItem(level: level, number: nil, line: line))
                continue
            case .numbered(let level, let number, let line):
                list.append(ListItem(level: level, number: number, line: line))
                continue
            default:
                flushList()
            }
            switch block {
            case .paragraph(let line):
                out.append("<p>\(inline(line))</p>")
            case .heading(let level, let line):
                out.append("<h\(level)>\(inline(line))</h\(level)>")
            case .code(let code):
                out.append("<pre><code>\(escape(code))</code></pre>")
            case .quote(let inner):
                let blocks = MarkdownText.blocks(in: inner)
                // Inside a quote even a lone line is a paragraph.
                let body = blocks.count == 1 ? "<p>\(html(blocks))</p>" : html(blocks)
                out.append("<blockquote>\(body)</blockquote>")
            case .rule:
                out.append("<hr>")
            case .table(let header, let rows):
                let head = header.map { "<th>\(inline($0))</th>" }.joined()
                let body = rows.map { row in "<tr>" + row.map { "<td>\(inline($0))</td>" }.joined() + "</tr>" }.joined()
                out.append("<table><thead><tr>\(head)</tr></thead><tbody>\(body)</tbody></table>")
            case .bullet, .numbered:
                break
            }
        }
        flushList()
        return out.joined(separator: "\n")
    }

    private struct ListItem {
        var level: Int
        /// Nil for a bullet.
        var number: String?
        var line: String
    }

    /// Items nest by level: a deeper item's list sits inside the item above it.
    private static func listHTML(_ items: [ListItem]) -> String {
        var out = ""
        var open: [(level: Int, tag: String)] = []
        func close() {
            out += "</li></\(open.removeLast().tag)>"
        }
        for item in items {
            let tag = item.number == nil ? "ul" : "ol"
            while let top = open.last, top.level > item.level { close() }
            if let top = open.last, top.level == item.level, top.tag != tag { close() }
            if let top = open.last, top.level == item.level {
                out += "</li>"
            } else {
                if let number = item.number, let start = Int(number), start != 1 {
                    out += "<ol start=\"\(start)\">"
                } else {
                    out += "<\(tag)>"
                }
                open.append((item.level, tag))
            }
            out += "<li>\(inline(item.line))"
        }
        while !open.isEmpty { close() }
        return out
    }

    static func inline(_ line: String) -> String {
        let parsed = MarkdownText.parseInline(line)
        var out = ""
        for run in parsed.runs {
            var piece = escape(String(parsed[run.range].characters))
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) { piece = "<code>\(piece)</code>" }
            if intent.contains(.strikethrough) { piece = "<del>\(piece)</del>" }
            if intent.contains(.emphasized) { piece = "<em>\(piece)</em>" }
            if intent.contains(.stronglyEmphasized) { piece = "<strong>\(piece)</strong>" }
            if let link = run.link { piece = "<a href=\"\(escape(link.absoluteString))\">\(piece)</a>" }
            out += piece
        }
        return out
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    #if os(macOS)
    /// Puts Markdown on a pasteboard twice over: as itself, for editors,
    /// terminals and anything else that takes plain text, and as HTML, for
    /// apps that take formatted text.
    public static func copy(_ markdown: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.declareTypes([.html, .string], owner: nil)
        pasteboard.setString("<meta charset=\"utf-8\">" + html(markdown), forType: .html)
        pasteboard.setString(markdown, forType: .string)
    }
    #endif
}
