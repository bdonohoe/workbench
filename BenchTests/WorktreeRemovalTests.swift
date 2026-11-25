import Foundation
import Testing
@testable import Bench

/// Removing a worktree's folder: deleted for good by default, or moved to
/// the Trash when Settings says so.
struct WorktreeRemovalTests {
    /// A "<repo>.worktrees" folder with one worktree holding a file.
    private func worktree() throws -> (shared: URL, worktree: URL) {
        let shared = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorktreeRemovalTests-\(UUID().uuidString)")
            .appendingPathComponent("Thing.worktrees")
        let worktree = shared.appendingPathComponent("feat-menu-bar")
        try FileManager.default.createDirectory(at: worktree.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try "SECRET=1".write(to: worktree.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        return (shared, worktree)
    }

    @Test func deletingTakesTheFolderAwayAtOnce() async throws {
        let (shared, worktree) = try worktree()
        let deletion = try Worktrees.removeFolder(worktree: worktree, toTrash: false)
        // Gone from its path before the contents are deleted.
        #expect(!FileManager.default.fileExists(atPath: worktree.path))
        await deletion?.value
        // Nothing left behind, and the emptied worktrees folder goes too.
        #expect(!FileManager.default.fileExists(atPath: shared.path))
    }

    @Test func deletingLeavesOtherWorktreesAlone() async throws {
        let (shared, worktree) = try worktree()
        let other = shared.appendingPathComponent("fix-crash")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try await Worktrees.removeFolder(worktree: worktree, toTrash: false)?.value
        #expect(try FileManager.default.contentsOfDirectory(atPath: shared.path) == ["fix-crash"])
    }

    @Test func deletingFinishesOneThatWasInterrupted() async throws {
        let (shared, worktree) = try worktree()
        let stray = shared.appendingPathComponent(".old-branch.1234abcd.bench-deleting")
        try FileManager.default.createDirectory(at: stray.appendingPathComponent("build"), withIntermediateDirectories: true)
        try await Worktrees.removeFolder(worktree: worktree, toTrash: false)?.value
        #expect(!FileManager.default.fileExists(atPath: stray.path))
    }

    @Test func aMissingFolderIsNotAnError() throws {
        let gone = FileManager.default.temporaryDirectory.appendingPathComponent("WorktreeRemovalTests-gone-\(UUID().uuidString)")
        #expect(try Worktrees.removeFolder(worktree: gone, toTrash: false) == nil)
        #expect(try Worktrees.removeFolder(worktree: gone, toTrash: true) == nil)
    }
}
