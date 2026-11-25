import Testing
@testable import BenchKit

/// A newline typed at the end of `text`.
private func newline(atEndOf text: String) -> String {
    let edit = ListShorthand.newline(in: text, replacing: text.endIndex..<text.endIndex)
    return ListShorthand.apply(edit, to: text).text
}

/// A newline typed where `|` is in `text`, with the cursor shown as `|` in the result.
private func newline(at marked: String) -> String {
    var text = marked
    guard let bar = text.firstIndex(of: "|") else { return marked }
    text.remove(at: bar)
    let edit = ListShorthand.newline(in: text, replacing: bar..<bar)
    var (result, cursor) = ListShorthand.apply(edit, to: text)
    result.insert("|", at: cursor)
    return result
}

@Test func plainLinesGetAPlainNewline() {
    #expect(newline(atEndOf: "Hello") == "Hello\n")
    #expect(newline(atEndOf: "") == "\n")
    #expect(newline(atEndOf: "-no space") == "-no space\n")
    #expect(newline(atEndOf: "1.5 is fine") == "1.5 is fine\n")
}

@Test func bulletsContinue() {
    #expect(newline(atEndOf: "- one") == "- one\n- ")
    #expect(newline(atEndOf: "* one") == "* one\n* ")
    #expect(newline(atEndOf: "+ one") == "+ one\n+ ")
    #expect(newline(atEndOf: "• one") == "• one\n• ")
    #expect(newline(atEndOf: "Intro:\n- one\n- two") == "Intro:\n- one\n- two\n- ")
}

@Test func numbersCountUp() {
    #expect(newline(atEndOf: "1. yes") == "1. yes\n2. ")
    #expect(newline(atEndOf: "9. yes") == "9. yes\n10. ")
    #expect(newline(atEndOf: "3) yes") == "3) yes\n4) ")
}

@Test func checkboxesContinueUnchecked() {
    #expect(newline(atEndOf: "- [ ] one") == "- [ ] one\n- [ ] ")
    #expect(newline(atEndOf: "- [x] one") == "- [x] one\n- [ ] ")
}

@Test func indentIsKept() {
    #expect(newline(atEndOf: "- one\n  - nested") == "- one\n  - nested\n  - ")
    #expect(newline(atEndOf: "\t1. one") == "\t1. one\n\t2. ")
}

@Test func anEmptyItemEndsTheList() {
    #expect(newline(atEndOf: "- one\n- ") == "- one\n")
    #expect(newline(atEndOf: "1. one\n2. ") == "1. one\n")
    #expect(newline(atEndOf: "- one\n  - ") == "- one\n")
    #expect(newline(atEndOf: "- [ ] one\n- [ ] ") == "- [ ] one\n")
    // Only when it's really empty: a space after the marker still counts as empty.
    #expect(newline(atEndOf: "- one\n-  ") == "- one\n")
}

@Test func theCursorLandsAfterTheMarker() {
    #expect(newline(at: "- one|") == "- one\n- |")
    #expect(newline(at: "1. one|\n3. three") == "1. one\n2. |\n3. three")
    #expect(newline(at: "- one|\n- ") == "- one\n- |\n- ")
}

@Test func textAfterTheCursorMovesToTheNewItem() {
    #expect(newline(at: "- one |two") == "- one \n- |two")
    // An empty item with text after the cursor isn't the end of the list.
    #expect(newline(at: "- |two") == "- \n- |two")
}

@Test func aCursorInsideTheMarkerIsAPlainNewline() {
    #expect(newline(at: "-| one") == "-\n| one")
}

@Test func aSelectionIsReplaced() {
    let text = "- one two"
    let start = text.index(text.startIndex, offsetBy: 5)
    let edit = ListShorthand.newline(in: text, replacing: start..<text.endIndex)
    #expect(ListShorthand.apply(edit, to: text).text == "- one\n- ")
}
