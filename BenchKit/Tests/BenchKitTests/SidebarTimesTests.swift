import Foundation
import Testing
@testable import BenchKit

struct SidebarTimesTests {
    private let hour: TimeInterval = 3600
    private var day: TimeInterval { 24 * hour }

    @Test func names() {
        #expect(SidebarTimes.name(hour) == "1 hour")
        #expect(SidebarTimes.name(6 * hour) == "6 hours")
        #expect(SidebarTimes.name(day) == "1 day")
        #expect(SidebarTimes.name(3 * day) == "3 days")
        #expect(SidebarTimes.name(7 * day) == "1 week")
        #expect(SidebarTimes.name(14 * day) == "2 weeks")
        #expect(SidebarTimes.name(30 * day) == "1 month")
    }

    @Test func recentHints() {
        #expect(SidebarTimes.recentHint(inactiveAfter: day) == "Last day")
        #expect(SidebarTimes.recentHint(inactiveAfter: 3 * day) == "Last 3 days")
        #expect(SidebarTimes.recentHint(inactiveAfter: 7 * day) == "Last week")
        #expect(SidebarTimes.recentHint(inactiveAfter: 14 * day) == "Last 2 weeks")
        #expect(SidebarTimes.recentHint(inactiveAfter: 30 * day) == "Last month")
        #expect(SidebarTimes.standard.recentHint == "Last day")
    }

    /// Inactive always comes after Active, so Recent has room.
    @Test func inactiveComesAfterActive() {
        #expect(SidebarTimes.inactiveChoices(after: 6 * hour) == SidebarTimes.inactiveChoices)
        #expect(SidebarTimes.inactiveChoices(after: day) == [3 * day, 7 * day, 14 * day, 30 * day])
        #expect(SidebarTimes(active: 3 * day, inactiveAfter: day).fitted.inactiveAfter == 7 * day)
        #expect(SidebarTimes(active: day, inactiveAfter: 14 * day).fitted.inactiveAfter == 14 * day)
        for active in SidebarTimes.activeChoices {
            #expect(!SidebarTimes.inactiveChoices(after: active).isEmpty)
        }
    }

    @Test func savedRoundTrip() throws {
        let defaults = try #require(UserDefaults(suiteName: "SidebarTimesTests-\(UUID())"))
        #expect(SidebarTimes.saved(in: defaults) == .standard)
        SidebarTimes(active: 12 * hour, inactiveAfter: 7 * day).save(in: defaults)
        #expect(SidebarTimes.saved(in: defaults) == SidebarTimes(active: 12 * hour, inactiveAfter: 7 * day))
        // A saved pair that overlaps (say, from editing defaults by hand) is fitted.
        SidebarTimes(active: 3 * day, inactiveAfter: day).save(in: defaults)
        #expect(SidebarTimes.saved(in: defaults).inactiveAfter == 7 * day)
    }
}

struct ProjectsSnapshotRecentHintTests {
    @Test func olderMacsMeanADay() throws {
        let old = try JSONDecoder().decode(ProjectsSnapshot.self, from: Data(#"{"projects":[]}"#.utf8))
        #expect(old.inactiveAfter == nil)
        #expect(old.recentHint == "Last day")
    }

    @Test func theMacsTimeComesThrough() throws {
        let sent = ProjectsSnapshot(projects: [], inactiveAfter: 14 * 24 * 3600)
        let read = try JSONDecoder().decode(ProjectsSnapshot.self, from: JSONEncoder().encode(sent))
        #expect(read.recentHint == "Last 2 weeks")
    }
}
