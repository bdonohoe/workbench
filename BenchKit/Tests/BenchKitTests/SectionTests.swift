import Foundation
import Testing
@testable import BenchKit

struct SectionTests {
    private func project(isActive: Bool? = nil, isPinned: Bool? = nil, section: CompanionSection? = nil) -> CompanionProject {
        CompanionProject(id: UUID(), name: "P", repoName: "p", path: "/p", activity: .idle,
                         isActive: isActive, isPinned: isPinned, section: section)
    }

    @Test func sentSectionWins() {
        #expect(project(isActive: true, isPinned: false, section: .recent).placement == .recent)
    }

    @Test func olderMacsFallBackToActiveAndPinned() {
        #expect(project(isActive: true, isPinned: true).placement == .pinned)
        #expect(project(isActive: true, isPinned: false).placement == .active)
        #expect(project(isActive: false, isPinned: false).placement == .inactive)
        #expect(project().placement == nil)
    }

    @Test func olderPhonesIgnoreTheNewField() throws {
        let data = try JSONEncoder().encode(project(isActive: true, section: .recent))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["section"] as? String == "recent")
        #expect(json["isActive"] as? Bool == true)
    }
}
