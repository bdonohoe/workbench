import Testing
@testable import BenchKit

/// Which pieces of inline code in a reply name a file on disk.
struct LocalFilePathTests {
    let root = "/Users/me/Apps/Bench"
    let home = "/Users/me"
    let files: Set<String> = [
        "/Users/me/Apps/Bench/Makefile",
        "/Users/me/Apps/Bench/Bench/App/BenchApp.swift",
        "/Users/me/Library/Application Support/Bench/state.json",
        "/private/tmp/sheet-popup.png",
        "/Users/me/Apps/Bench/notes:draft.md",
    ]
    let folders: Set<String> = [
        "/Users/me/Apps/Bench/Bench/App",
        "/Users/me/Apps/Bench/build",
        "/private/tmp",
    ]

    func lookup(_ path: String) -> LocalFilePath.Entry {
        files.contains(path) ? .file : folders.contains(path) ? .folder : .missing
    }

    func resolve(_ text: String, root: String? = "/Users/me/Apps/Bench") -> String? {
        LocalFilePath.resolve(text, root: root, home: home, lookup: lookup)
    }

    @Test func fullPathsAreThemselves() {
        #expect(resolve("/private/tmp/sheet-popup.png") == "/private/tmp/sheet-popup.png")
        #expect(resolve("  /private/tmp/sheet-popup.png\n") == "/private/tmp/sheet-popup.png")
    }

    @Test func projectPathsCountFromTheProject() {
        #expect(resolve("Bench/App/BenchApp.swift") == "/Users/me/Apps/Bench/Bench/App/BenchApp.swift")
        #expect(resolve("Makefile") == "/Users/me/Apps/Bench/Makefile")
        #expect(resolve("Bench/App/BenchApp.swift", root: "/Users/me/Apps/Bench/") == "/Users/me/Apps/Bench/Bench/App/BenchApp.swift")
        // Without a project there's nothing to count from.
        #expect(resolve("Bench/App/BenchApp.swift", root: nil) == nil)
    }

    @Test func tildeIsHome() {
        #expect(resolve("~/Library/Application Support/Bench/state.json") == "/Users/me/Library/Application Support/Bench/state.json")
        #expect(resolve("~/Apps/Bench/Makefile") == "/Users/me/Apps/Bench/Makefile")
        #expect(resolve("~/Apps/Bench/Missing") == nil)
    }

    @Test func lineAndColumnComeOff() {
        #expect(resolve("Makefile:29") == "/Users/me/Apps/Bench/Makefile")
        #expect(resolve("Bench/App/BenchApp.swift:12:5") == "/Users/me/Apps/Bench/Bench/App/BenchApp.swift")
        // A real colon in a name still wins when that file is there.
        #expect(resolve("notes:draft.md") == "/Users/me/Apps/Bench/notes:draft.md")
    }

    @Test func foldersCountWhenWrittenAsPaths() {
        #expect(resolve("Bench/App") == "/Users/me/Apps/Bench/Bench/App")
        #expect(resolve("Bench/App/") == "/Users/me/Apps/Bench/Bench/App")
        #expect(resolve("/private/tmp") == "/private/tmp")
        // A bare word matching a folder is a command or a branch, not a path.
        #expect(resolve("build") == nil)
        #expect(resolve("build/") == "/Users/me/Apps/Bench/build")
    }

    @Test func commandsAndNamesAreNotFiles() {
        #expect(resolve("make build") == nil)
        #expect(resolve("STRIPE_SECRET_KEY") == nil)
        #expect(resolve("railway") == nil)
        #expect(resolve("") == nil)
        #expect(resolve("Bench/Missing.swift") == nil)
        #expect(resolve("/nowhere/at/all.txt") == nil)
    }
}
