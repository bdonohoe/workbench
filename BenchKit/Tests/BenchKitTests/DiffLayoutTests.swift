import Foundation
import Testing
@testable import BenchKit

struct DiffLayoutTests {
    private func line(_ id: Int, _ kind: DiffLine.Kind, _ text: String) -> DiffLine {
        DiffLine(id: id, kind: kind, text: text, oldNumber: nil, newNumber: nil)
    }

    @Test func joinsLinesWithoutMarkers() {
        let layout = DiffLayout(lines: [line(0, .context, "a"), line(1, .added, "b"), line(2, .removed, "c")])
        #expect(layout.text == "a\nb\nc")
        #expect(layout.ranges == [NSRange(location: 0, length: 1), NSRange(location: 2, length: 1), NSRange(location: 4, length: 1)])
        #expect(layout.kinds == [.context, .added, .removed])
    }

    @Test func findsTheLineAtAnOffset() {
        let layout = DiffLayout(lines: [line(0, .context, "a"), line(1, .added, "b"), line(2, .removed, "c")])
        #expect(layout.line(at: 0) == 0)
        #expect(layout.line(at: 2) == 1)
        // The newline after "b" still belongs to line 1.
        #expect(layout.line(at: 3) == 1)
        #expect(layout.line(at: 4) == 2)
        // The end of the text is on the last line; past it is nowhere.
        #expect(layout.line(at: 5) == 2)
        #expect(layout.line(at: 6) == nil)
        #expect(layout.line(at: -1) == nil)
    }

    @Test func keepsHunkAndMetaLines() {
        let layout = DiffLayout(lines: [line(0, .meta, "new file mode 100644"), line(1, .hunk, "func main()"), line(2, .added, "x")])
        #expect(layout.text == "new file mode 100644\nfunc main()\nx")
        #expect(layout.kinds == [.meta, .hunk, .added])
    }

    @Test func rangesCountUTF16Units() {
        // "é" as one scalar is one UTF-16 unit; "😀" is two.
        let layout = DiffLayout(lines: [line(0, .context, "é"), line(1, .added, "😀"), line(2, .context, "z")])
        #expect(layout.ranges == [NSRange(location: 0, length: 1), NSRange(location: 2, length: 2), NSRange(location: 5, length: 1)])
        #expect(layout.line(at: 3) == 1)
        #expect(layout.line(at: 5) == 2)
        #expect((layout.text as NSString).substring(with: layout.ranges[2]) == "z")
    }

    @Test func emptyDiffHasNoLines() {
        let layout = DiffLayout(lines: [])
        #expect(layout.text == "")
        #expect(layout.ranges.isEmpty)
        #expect(layout.line(at: 0) == nil)
    }

    @Test func aReviewKnowsEachFilesLines() {
        let text = """
        diff --git a/one.swift b/one.swift
        --- a/one.swift
        +++ b/one.swift
        @@ -1,2 +1,2 @@
         let a = 1
        -let b = 2
        +let b = 3
        diff --git a/two.py b/two.py
        --- a/two.py
        +++ b/two.py
        @@ -1 +1 @@
        -x = 1
        +x = 2
        """
        let review = ReviewDiff(parsing: text)
        #expect(review.files.map(\.path) == ["one.swift", "two.py"])
        let first = review.lineRange(ofFileAt: 0), second = review.lineRange(ofFileAt: 1)
        // Each file's lines start after its header row and stop at the next one.
        #expect(first.lowerBound == review.files[0].headerLine + 1)
        #expect(first.upperBound == review.files[1].headerLine)
        #expect(second.lowerBound == review.files[1].headerLine + 1)
        #expect(second.upperBound == review.lines.count)
        #expect(review.lines[first].contains { $0.text == "let b = 3" })
        #expect(review.lines[second].contains { $0.text == "x = 2" })
        #expect(!review.lines[first].contains { $0.text == "x = 2" })
    }
}
