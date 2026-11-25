import Foundation
import Testing
@testable import BenchKit

struct CompanionGroupsTests {
    @Test func snapshotFromOlderMacHasNoGroups() throws {
        let json = #"{"projects": []}"#
        let snapshot = try JSONDecoder().decode(ProjectsSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.groups == nil)
    }

    @Test func groupsRoundTrip() throws {
        let id = UUID()
        let group = CompanionGroup(id: UUID(), name: "Shop", projectIDs: [id])
        let snapshot = ProjectsSnapshot(projects: [], groups: [group])
        let decoded = try JSONDecoder().decode(ProjectsSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.groups == [group])
    }
}
