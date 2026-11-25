import Foundation
import Testing
@testable import BenchKit

/// Files dropped on a terminal type their paths, escaped for the shell.
@Suite struct TerminalDropTests {
    @Test func aPlainPathIsTypedAsIs() {
        #expect(TerminalDrop.text(forPaths: ["/tmp/shot.png"]) == "/tmp/shot.png")
    }

    @Test func spacesAndShellCharactersAreEscaped() {
        #expect(TerminalDrop.escape("/Users/me/Desktop/Screenshot 2026-11-13 at 10.00.00.png")
            == "/Users/me/Desktop/Screenshot\\ 2026-11-13\\ at\\ 10.00.00.png")
        #expect(TerminalDrop.escape("a'b\"c$(d)&e") == "a\\'b\\\"c\\$\\(d\\)\\&e")
        #expect(TerminalDrop.escape("back\\slash") == "back\\\\slash")
    }

    @Test func severalPathsAreSeparatedBySpaces() {
        #expect(TerminalDrop.text(forPaths: ["/a b.png", "/c.png"]) == "/a\\ b.png /c.png")
    }

    @Test func nothingToTypeWithoutPaths() {
        #expect(TerminalDrop.text(forPaths: []) == nil)
        #expect(TerminalDrop.text(forPaths: [""]) == nil)
    }
}
