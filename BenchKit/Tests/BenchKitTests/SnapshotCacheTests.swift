import Foundation
import Testing
@testable import BenchKit

@Suite final class SnapshotCacheTests {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("SnapshotCacheTests-\(UUID().uuidString)", isDirectory: true)

    deinit { try? FileManager.default.removeItem(at: folder) }

    var cache: SnapshotCache { SnapshotCache(folder: folder) }

    func saved(_ name: String = "Bench", sessions: [CompanionSession] = []) -> SavedMac {
        let project = CompanionProject(id: UUID(), name: name, repoName: name, path: "/tmp/\(name)",
                                       activity: .idle, sessions: sessions, isGit: true)
        return SavedMac(snapshot: ProjectsSnapshot(projects: [project]),
                        features: [CompanionFeature.offlineQueue], macName: "Matt's Mac",
                        savedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    func session() -> CompanionSession {
        CompanionSession(id: UUID(), title: "Claude", activity: .working)
    }

    @Test func savesAndLoadsPerHost() throws {
        let original = saved()
        cache.save(original, host: "mac.tail.ts.net")
        let loaded = try #require(cache.load(host: "mac.tail.ts.net"))
        #expect(loaded.snapshot == original.snapshot)
        #expect(loaded.features == original.features)
        #expect(loaded.macName == "Matt's Mac")
        #expect(loaded.savedAt == original.savedAt)
    }

    @Test func differentHostsDontMix() throws {
        cache.save(saved("One"), host: "one.tail.ts.net")
        cache.save(saved("Two"), host: "two.tail.ts.net")
        let one = try #require(cache.load(host: "one.tail.ts.net"))
        let two = try #require(cache.load(host: "two.tail.ts.net"))
        #expect(one.snapshot.projects.map(\.name) == ["One"])
        #expect(two.snapshot.projects.map(\.name) == ["Two"])
    }

    @Test func sessionsAreDropped() throws {
        cache.save(saved(sessions: [session()]), host: "mac.tail.ts.net")
        let loaded = try #require(cache.load(host: "mac.tail.ts.net"))
        #expect(loaded.snapshot.projects.allSatisfy { $0.sessions.isEmpty })
    }

    @Test func fileNameDoesNotContainHost() throws {
        cache.save(saved(), host: "matts-mac.tail.ts.net")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(names == [NotificationSeal.opaque("matts-mac.tail.ts.net") + ".json"])
        #expect(names.allSatisfy { !$0.contains("matts-mac") })
    }

    @Test func removeDeletes() {
        cache.save(saved(), host: "mac.tail.ts.net")
        cache.remove(host: "mac.tail.ts.net")
        #expect(cache.load(host: "mac.tail.ts.net") == nil)
    }

    @Test func folderIsKeptOutOfBackups() throws {
        cache.save(saved(), host: "mac.tail.ts.net")
        #expect(try folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test func movesToNewHost() throws {
        let original = saved()
        cache.save(original, host: "a")
        cache.move(from: "a", to: "b")
        let moved = try #require(cache.load(host: "b"))
        #expect(moved.snapshot == original.snapshot)
        #expect(moved.macName == original.macName)
        #expect(moved.savedAt == original.savedAt)
        #expect(cache.load(host: "a") == nil)
    }

    @Test func moveReplacesWhatTheNewHostHad() throws {
        cache.save(saved("Old"), host: "a")
        cache.save(saved("Stale"), host: "b")
        cache.move(from: "a", to: "b")
        #expect(try #require(cache.load(host: "b")).snapshot.projects.map(\.name) == ["Old"])
        #expect(cache.load(host: "a") == nil)
    }

    @Test func missingFileLoadsNil() {
        #expect(cache.load(host: "never.tail.ts.net") == nil)
    }
}
