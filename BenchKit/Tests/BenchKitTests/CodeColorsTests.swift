import Foundation
import Testing
@testable import BenchKit

struct CodeColorsTests {
    @Test func runsSplitAcrossLines() {
        let lines = [
            DiffLine(id: 0, kind: .context, text: "let a = 1", oldNumber: 1, newNumber: 1),
            DiffLine(id: 1, kind: .added, text: "/* two", oldNumber: nil, newNumber: 2),
            DiffLine(id: 2, kind: .added, text: "lines */", oldNumber: nil, newNumber: 3),
        ]
        let layout = DiffLayout(lines: lines)
        // "let" at 0, and a comment from the start of line 1 to the end of line 2.
        let runs = layout.runsByLine([CodeRun(start: 0, length: 3, kind: .keyword),
                                      CodeRun(start: 10, length: 15, kind: .comment)])
        #expect(runs[0] == [CodeRun(start: 0, length: 3, kind: .keyword)])
        #expect(runs[1] == [CodeRun(start: 0, length: 6, kind: .comment)])
        #expect(runs[2] == [CodeRun(start: 0, length: 8, kind: .comment)])
    }

    @Test func codeTextKeepsTheWholeText() {
        let text = "let name = \"é😀\" // hi"
        let runs = [CodeRun(start: 0, length: 3, kind: .keyword), CodeRun(start: 11, length: 5, kind: .string),
                    CodeRun(start: 17, length: 5, kind: .comment), CodeRun(start: 1, length: 2, kind: .type)]
        #expect(String(codeText(text, runs: runs).characters) == text)
    }
}
