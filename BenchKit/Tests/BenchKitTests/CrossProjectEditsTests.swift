import Foundation
import Testing
@testable import BenchKit

private let roots: [CrossProjectEdits.Root<String>] = [
    .init(id: "chrome", path: "/Users/me/Apps/QuickReads Chrome"),
    .init(id: "safari", path: "/Users/me/Apps/QuickReads Safari"),
    .init(id: "bench", path: "/Users/me/Apps/Bench"),
    .init(id: "nested", path: "/Users/me/Apps/Bench/.worktrees/fix"),
    .init(id: "sibling", path: "/Users/me/Apps/Bench.worktrees/feat"),
]

@Test func matchesAFileToItsProject() {
    #expect(CrossProjectEdits.owner(of: "/Users/me/Apps/QuickReads Safari/src/popup.js", among: roots) == "safari")
    #expect(CrossProjectEdits.owner(of: "/Users/me/Apps/Bench/README.md", among: roots) == "bench")
}

@Test func theDeepestProjectFolderWins() {
    #expect(CrossProjectEdits.owner(of: "/Users/me/Apps/Bench/.worktrees/fix/a.swift", among: roots) == "nested")
}

@Test func aFolderWithTheSameStartIsntInside() {
    #expect(CrossProjectEdits.owner(of: "/Users/me/Apps/Bench.worktrees/feat/a.swift", among: roots) == "sibling")
    #expect(CrossProjectEdits.owner(of: "/Users/me/Apps/Benchmark/a.swift", among: roots) == nil)
    #expect(CrossProjectEdits.owner(of: "/Users/me/Apps/Bench", among: roots) == nil)
}

@Test func aTrailingSlashOnAFolderDoesntMatter() {
    let slashed: [CrossProjectEdits.Root<String>] = [.init(id: "bench", path: "/Users/me/Apps/Bench/")]
    #expect(CrossProjectEdits.owner(of: "/Users/me/Apps/Bench/README.md", among: slashed) == "bench")
    #expect(CrossProjectEdits.owner(of: "/Users/me/Apps/Benchmark/a.swift", among: slashed) == nil)
}

@Test func anAccentedFolderMatchesHoweverItIsComposed() {
    let composed = "/Users/me/Apps/Caf\u{E9}", decomposed = "/Users/me/Apps/Cafe\u{301}"
    #expect(CrossProjectEdits.owner(of: decomposed + "/a.swift", among: [.init(id: "cafe", path: composed)]) == "cafe")
    #expect(CrossProjectEdits.owner(of: composed + "/a.swift", among: [.init(id: "cafe", path: decomposed)]) == "cafe")
}

@Test func anIndexAnswersLikeTheOneOffCalls() {
    let index = CrossProjectEdits.Index(roots)
    #expect(index.owner(of: "/Users/me/Apps/Bench/.worktrees/fix/a.swift") == "nested")
    #expect(index.owner(of: "/Users/me/Apps/Bench/README.md") == "bench")
    #expect(index.owner(of: "/Users/me/elsewhere.txt") == nil)
    #expect(index.roots == roots)
}

@Test func groupsOnlyOtherProjectsEdits() {
    let now = Date()
    let files = ["/Users/me/Apps/QuickReads Chrome/a.js": now,
                 "/Users/me/Apps/QuickReads Safari/a.js": now,
                 "/Users/me/Apps/QuickReads Safari/b.js": now,
                 "/Users/me/.claude/plans/plan.md": now]
    let grouped = CrossProjectEdits.byProject(files, home: "chrome", roots: roots)
    #expect(grouped.keys.sorted() == ["safari"])
    #expect(grouped["safari"]?.count == 2)
}

@Test func readsEditedFilesFromATranscriptLine() {
    let entry: [String: Any] = [
        "type": "assistant",
        "message": ["content": [
            ["type": "text", "text": "Making the same change in Safari."],
            ["type": "tool_use", "name": "Edit", "input": ["file_path": "/Users/me/Apps/QuickReads Safari/./a.js"]],
            ["type": "tool_use", "name": "Write", "input": ["file_path": "/tmp/x.txt"]],
            ["type": "tool_use", "name": "NotebookEdit", "input": ["notebook_path": "/Users/me/n.ipynb"]],
            ["type": "tool_use", "name": "Read", "input": ["file_path": "/Users/me/read.txt"]],
            ["type": "tool_use", "name": "Edit", "input": ["file_path": "relative.txt"]],
        ]],
    ]
    #expect(CrossProjectEdits.editedFiles(in: entry) == ["/Users/me/Apps/QuickReads Safari/a.js", "/tmp/x.txt", "/Users/me/n.ipynb"])
    #expect(CrossProjectEdits.editedFiles(in: ["type": "user"]).isEmpty)
}
