import BenchKit
import Foundation
import Testing
@testable import Bench

/// Active, Recent and Inactive follow the times in Settings, and a
/// project's tabs only close on the way to Inactive when that's turned on.
/// The test host shares the real app's defaults, so each test puts back
/// whatever was saved before it.
@MainActor
struct SidebarSectionTimesTests {
    private let hour: TimeInterval = 3600
    private static let keys = [SidebarTimes.activeKey, SidebarTimes.inactiveKey, AppStore.closesInactiveTabsKey]
    private let saved: [String: Any?]

    init() {
        saved = Dictionary(uniqueKeysWithValues: Self.keys.map { ($0, UserDefaults.standard.object(forKey: $0)) })
    }

    private func restoreDefaults() {
        for (key, value) in saved {
            if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bench-times-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func storeWithProject() throws -> (AppStore, UUID) {
        let store = AppStore(fileURL: try folder().appendingPathComponent("state.json"))
        store.sidebarTimes = .standard
        store.closesInactiveTabs = true
        guard case .added(let project) = store.addProject(path: try folder().path, source: .folderPicker) else {
            throw CancellationError()
        }
        return (store, project.id)
    }

    @Test func sectionsFollowTheTimes() throws {
        let (store, id) = try storeWithProject()
        defer { restoreDefaults() }
        #expect(store.section(of: id) == .active)

        // Eight hours on: Recent with the standard 6 hours of Active.
        store.now = .now.addingTimeInterval(8 * hour)
        #expect(store.section(of: id) == .recent)
        // Twelve hours of Active brings it back.
        store.sidebarTimes = SidebarTimes(active: 12 * hour, inactiveAfter: 24 * hour)
        #expect(store.section(of: id) == .active)

        // Two days on: Inactive after a day, Recent after a week.
        store.now = .now.addingTimeInterval(48 * hour)
        #expect(store.section(of: id) == .inactive)
        store.sidebarTimes = SidebarTimes(active: 12 * hour, inactiveAfter: 7 * 24 * hour)
        #expect(store.section(of: id) == .recent)
    }

    @Test func inactiveIsPushedPastActive() throws {
        let (store, _) = try storeWithProject()
        defer { restoreDefaults() }
        store.sidebarTimes = SidebarTimes(active: 3 * 24 * hour, inactiveAfter: 24 * hour)
        #expect(store.sidebarTimes.inactiveAfter == 7 * 24 * hour)
        #expect(SidebarTimes.saved().inactiveAfter == 7 * 24 * hour)
    }

    @Test func tabsStayWhenClosingIsOff() throws {
        let (store, id) = try storeWithProject()
        defer { restoreDefaults() }
        store.selectedProjectID = nil
        store.closesInactiveTabs = false
        store.now = .now.addingTimeInterval(48 * hour)
        store.closeInactiveTabs(includingSelected: true)
        #expect(store.project(id)?.tabs.isEmpty == false)

        store.closesInactiveTabs = true
        #expect(store.project(id)?.tabs.isEmpty == true)
    }
}
