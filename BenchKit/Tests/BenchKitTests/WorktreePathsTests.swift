import Foundation
import Testing
@testable import BenchKit

private let repo = URL(fileURLWithPath: "/Users/me/Apps/Bench")
private let chosen = URL(fileURLWithPath: "/Users/me/worktrees")

@Test func defaultFolderSitsNextToTheRepo() {
    let folder = WorktreePaths.folder(forRepo: repo, branch: "feat/menu-bar", chosenFolder: nil)
    #expect(folder.path == "/Users/me/Apps/Bench.worktrees/feat-menu-bar")
}

@Test func chosenFolderGetsASubfolderPerRepo() {
    let folder = WorktreePaths.folder(forRepo: repo, branch: "feat/menu-bar", chosenFolder: chosen)
    #expect(folder.path == "/Users/me/worktrees/Bench/feat-menu-bar")
    let other = WorktreePaths.folder(forRepo: URL(fileURLWithPath: "/Users/me/Apps/pitwall"), branch: "feat/menu-bar", chosenFolder: chosen)
    #expect(other != folder)
}

@Test func neverRemovesTheChosenFolder() {
    #expect(!WorktreePaths.canRemoveWhenEmpty(chosen, chosenFolder: chosen))
    let named = URL(fileURLWithPath: "/Users/me/Bench.worktrees")
    #expect(!WorktreePaths.canRemoveWhenEmpty(named, chosenFolder: named))
}

@Test func removesFoldersWorkbenchMade() {
    #expect(WorktreePaths.canRemoveWhenEmpty(chosen.appendingPathComponent("Bench"), chosenFolder: chosen))
    #expect(WorktreePaths.canRemoveWhenEmpty(URL(fileURLWithPath: "/Users/me/Apps/Bench.worktrees"), chosenFolder: nil))
    #expect(WorktreePaths.canRemoveWhenEmpty(URL(fileURLWithPath: "/Users/me/Apps/Bench.worktrees"), chosenFolder: chosen))
}

@Test func leavesOtherFoldersAlone() {
    #expect(!WorktreePaths.canRemoveWhenEmpty(URL(fileURLWithPath: "/Users/me/Apps"), chosenFolder: nil))
    #expect(!WorktreePaths.canRemoveWhenEmpty(URL(fileURLWithPath: "/Users/me/Apps"), chosenFolder: chosen))
    // A folder you used to choose isn't Workbench's to remove.
    #expect(!WorktreePaths.canRemoveWhenEmpty(chosen.appendingPathComponent("Bench"), chosenFolder: nil))
}

@Test func findsTheRepoFromAFolder() {
    #expect(WorktreePaths.repoName(forFolder: "/Users/me/worktrees/Bench/feat-x", chosenFolder: "/Users/me/worktrees") == "Bench")
    #expect(WorktreePaths.repoName(forFolder: "/Users/me/worktrees/Bench/feat-x/src", chosenFolder: "/Users/me/worktrees/") == "Bench")
    #expect(WorktreePaths.repoName(forFolder: "/Users/me/Apps/Bench.worktrees/feat-x", chosenFolder: nil) == "Bench")
    #expect(WorktreePaths.repoName(forFolder: "/Users/me/Apps/Bench.worktrees/feat-x", chosenFolder: "/Users/me/worktrees") == "Bench")
    #expect(WorktreePaths.repoName(forFolder: "/Users/me/Apps/Bench", chosenFolder: "/Users/me/worktrees") == nil)
    #expect(WorktreePaths.repoName(forFolder: "/Users/me/worktrees-old/Bench", chosenFolder: "/Users/me/worktrees") == nil)
}
