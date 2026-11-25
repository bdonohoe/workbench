import Testing
@testable import BenchKit

@MainActor @Test func copiesATableAsMarkdown() {
    let markdown = MarkdownText.tableMarkdown(header: ["Plan", "Price"], rows: [["Free", "$0"], ["Pro"]])
    #expect(markdown == """
    | Plan | Price |
    | ---- | ----- |
    | Free | $0    |
    | Pro  |       |
    """)
}

@MainActor @Test func copiedTableKeepsPipesInCells() {
    let source = "| Flag | Meaning |\n|---|---|\n| `a\\|b` | either \\| or |"
    guard case let .table(header, rows) = MarkdownText.blocks(in: source).first else {
        Issue.record("not a table"); return
    }
    let copied = MarkdownText.tableMarkdown(header: header, rows: rows)
    // Copying and parsing again gives the same table.
    #expect(MarkdownText.blocks(in: copied).first == .table(header: header, rows: rows))
}
