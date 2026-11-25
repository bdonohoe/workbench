import Foundation
import Testing
@testable import Bench

/// Two or more merged worktrees fold into one line under their project,
/// except the one on screen, and folded ones get no ⌘ number.
@MainActor
struct MergedWorktreesTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bench-merged-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A project with four worktrees, of which `merged` (by index) are merged.
    private func setUp(merged: Set<Int>) throws -> (AppStore, Project, [UUID]) {
        let store = AppStore(fileURL: try folder().appendingPathComponent("state.json"))
        guard case .added(let project) = store.addProject(path: try folder().path, source: .folderPicker) else {
            throw CancellationError()
        }
        let ids = try (0..<4).map { index in
            store.addWorktree(parent: project, path: try folder().path, branch: "agent-\(index)", base: nil,
                              prompt: nil, setupCommand: nil, select: false)
        }
        let mergedIDs = Set(merged.map { ids[$0] })
        store.isMergedAndIdle = { mergedIDs.contains($0) }
        store.selectedProjectID = project.id
        return (store, project, ids)
    }

    @Test func oneMergedWorktreeStaysARow() throws {
        let (store, project, ids) = try setUp(merged: [1])
        let list = store.sidebarWorktrees(of: project.id)
        #expect(list.merged.isEmpty)
        #expect(list.listed.map(\.id) == ids)
    }

    @Test func severalFoldIntoOneLine() throws {
        let (store, project, ids) = try setUp(merged: [0, 2, 3])
        let list = store.sidebarWorktrees(of: project.id)
        #expect(list.isFolded)
        #expect(list.merged.map(\.id) == [ids[0], ids[2], ids[3]])
        #expect(list.listed.map(\.id) == [ids[1]])

        // Shown again, they come after the others, under the line.
        store.expandedMerged.insert(project.id)
        let expanded = store.sidebarWorktrees(of: project.id)
        #expect(!expanded.isFolded)
        #expect(expanded.listed.map(\.id) == [ids[1], ids[0], ids[2], ids[3]])
    }

    @Test func theOneOnScreenIsNeverFolded() throws {
        let (store, project, ids) = try setUp(merged: [0, 2])
        store.selectedProjectID = ids[2]
        // That leaves one merged, which stays a row like any other.
        let list = store.sidebarWorktrees(of: project.id)
        #expect(list.merged.isEmpty)
        #expect(list.listed.map(\.id) == ids)
    }
}
