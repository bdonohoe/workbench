import Foundation
import Testing
@testable import Bench

/// Active lists projects with open tabs above ones without, so closing a
/// project's last tab drops it below the projects you're still working in.
@MainActor
struct ActiveOrderTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bench-active-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func closingTheLastTabDropsAProjectBelowOnesWithTabs() throws {
        let dir = try folder()
        let store = AppStore(fileURL: dir.appendingPathComponent("state.json"))
        let older = try folder(), newer = try folder()
        guard case .added(let first) = store.addProject(path: older.path, source: .folderPicker),
              case .added(let second) = store.addProject(path: newer.path, source: .folderPicker) else {
            Issue.record("projects weren't added"); return
        }
        // Newest arrival first while both have tabs.
        #expect(store.activeProjects.map(\.id) == [second.id, first.id])

        let tab = try #require(store.project(second.id)?.tabs.first)
        store.closeTab(tab.id, in: second.id)
        #expect(store.activeProjects.map(\.id) == [first.id, second.id])
        #expect(store.topLevelProjects.map(\.id) == [first.id, second.id])

        // Opening a tab again brings it back up.
        _ = store.addTab(.shell, to: second.id)
        #expect(store.activeProjects.map(\.id) == [second.id, first.id])
    }
}
