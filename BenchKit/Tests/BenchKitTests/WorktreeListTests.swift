import Foundation
import Testing
@testable import BenchKit

private let porcelain = """
worktree /Users/me/Apps/Bench
HEAD 1111111111111111111111111111111111111111
branch refs/heads/main

worktree /Users/me/elsewhere/feature x
HEAD 2222222222222222222222222222222222222222
branch refs/heads/feat/x

worktree /Users/me/elsewhere/detached
HEAD 3333333333333333333333333333333333333333
detached

worktree /Users/me/elsewhere/locked
HEAD 4444444444444444444444444444444444444444
branch refs/heads/feat/locked
locked because it's on a drive

worktree /Users/me/elsewhere/gone
HEAD 5555555555555555555555555555555555555555
branch refs/heads/feat/gone
prunable gitdir file points to non-existent location

worktree /Users/me/Apps/Bench/.claude/worktrees/quick-fix
HEAD 6666666666666666666666666666666666666666
branch refs/heads/claude/quick-fix

"""

@Test func parsesEveryKindOfWorktree() {
    let entries = WorktreeList.parse(porcelain)
    #expect(entries.count == 6)
    #expect(entries[0] == .init(path: "/Users/me/Apps/Bench", branch: "main"))
    #expect(entries[1] == .init(path: "/Users/me/elsewhere/feature x", branch: "feat/x"))
    #expect(entries[2].branch == nil)
    #expect(entries[3].branch == "feat/locked")
    #expect(!entries[3].isPrunable)
    #expect(entries[4].isPrunable)
}

@Test func parsesNothingFromNothing() {
    #expect(WorktreeList.parse("").isEmpty)
}

@Test func importsLinkedWorktreesOnly() {
    let paths = WorktreeList.importable(WorktreeList.parse(porcelain), known: [], hidden: []).map(\.path)
    #expect(paths == ["/Users/me/elsewhere/feature x", "/Users/me/elsewhere/detached", "/Users/me/elsewhere/locked",
                      "/Users/me/Apps/Bench/.claude/worktrees/quick-fix"])
}

@Test func skipsKnownAndHiddenWorktrees() {
    let paths = WorktreeList.importable(WorktreeList.parse(porcelain),
                                        known: ["/Users/me/elsewhere/feature x"],
                                        hidden: ["/Users/me/elsewhere/detached"]).map(\.path)
    #expect(paths == ["/Users/me/elsewhere/locked", "/Users/me/Apps/Bench/.claude/worktrees/quick-fix"])
}

@Test func recognizesTheMainWorktree() {
    let entries = WorktreeList.parse(porcelain)
    #expect(WorktreeList.isMainWorktree("/Users/me/Apps/Bench", of: entries))
    #expect(WorktreeList.isMainWorktree("/Users/me/Apps/Bench/", of: entries))
    #expect(!WorktreeList.isMainWorktree("/Users/me/elsewhere/feature x", of: entries))
    #expect(!WorktreeList.isMainWorktree("/Users/me/Apps/Bench", of: []))
}

@Test func aBareRepoHasNoMainWorktree() {
    let entries = WorktreeList.parse("worktree /Users/me/repo.git\nbare\n\nworktree /Users/me/repo/main\nHEAD 1\nbranch refs/heads/main\n")
    #expect(entries[0].isBare)
    #expect(!WorktreeList.isMainWorktree("/Users/me/repo.git", of: entries))
    #expect(!WorktreeList.isMainWorktree("/Users/me/repo/main", of: entries))
}

@Test func comparesPathsThroughSymlinks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let real = root.appendingPathComponent("real")
    let link = root.appendingPathComponent("link")
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

    let entries = [WorktreeList.Entry(path: "/main", branch: "main"), WorktreeList.Entry(path: real.path, branch: "x")]
    #expect(WorktreeList.importable(entries, known: [link.path], hidden: []).isEmpty)
    #expect(WorktreeList.importable(entries, known: [], hidden: [link.path]).isEmpty)
}
