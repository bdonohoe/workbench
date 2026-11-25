import Foundation
import Testing
@testable import Bench

/// The project list on disk, as read at launch: a tab Workbench doesn't
/// know is dropped on its own, and a file it can't read is set aside
/// rather than written over.
@MainActor
struct StateFileTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bench-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aTabOfAnUnknownKindIsDroppedAndTheProjectKept() throws {
        let file = try folder().appendingPathComponent("state.json")
        let project = UUID(), shell = UUID()
        let json = """
        {"projects":[{"id":"\(project.uuidString)","path":"/tmp/example","tabs":[
          {"id":"\(UUID().uuidString)","kind":"hologram","title":"From the future"},
          {"id":"\(shell.uuidString)","kind":"shell","title":"zsh"}
        ]}],"pins":[],"groups":[]}
        """
        try Data(json.utf8).write(to: file)
        let store = AppStore(fileURL: file)
        #expect(store.brokenStateFile == nil)
        #expect(store.projects.map(\.id) == [project])
        #expect(store.projects.first?.tabs.map(\.id) == [shell])
    }

    @Test func aFileThatCannotBeReadIsSetAsideNotOverwritten() throws {
        let dir = try folder()
        let file = dir.appendingPathComponent("state.json")
        try Data(#"{"projects":[{"id":"#.utf8).write(to: file)
        let store = AppStore(fileURL: file)
        #expect(store.projects.isEmpty)
        let aside = try #require(store.brokenStateFile)
        #expect(aside != file)
        #expect(aside.lastPathComponent.hasPrefix("state.json.broken-"))
        #expect(FileManager.default.fileExists(atPath: aside.path))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try String(contentsOf: aside, encoding: .utf8) == #"{"projects":[{"id":"#)
    }

    @Test func noFileMeansAnEmptyListAndNothingSetAside() throws {
        let file = try folder().appendingPathComponent("state.json")
        let store = AppStore(fileURL: file)
        #expect(store.projects.isEmpty)
        #expect(store.brokenStateFile == nil)
    }
}
