import Foundation
#if os(iOS)
import ActivityKit
#endif

/// A single Claude session on the iPhone's lock screen, from builds before
/// the dashboard (`DashboardAttributes`). Kept so the phone can end any
/// that are still showing.
public struct BenchActivityAttributes: Codable, Sendable, Hashable {
    public struct ContentState: Codable, Sendable, Hashable {
        /// `ActivityKind`'s raw value: working, waiting, done, idle.
        public var activity: String
        /// What it's doing, asking, or said last.
        public var text: String
        public var updatedAt: Date

        public init(activity: String, text: String, updatedAt: Date) {
            self.activity = activity
            self.text = text
            self.updatedAt = updatedAt
        }
    }

    public var projectID: UUID
    public var sessionID: UUID
    public var projectName: String

    public init(projectID: UUID, sessionID: UUID, projectName: String) {
        self.projectID = projectID
        self.sessionID = sessionID
        self.projectName = projectName
    }
}

#if os(iOS)
extension BenchActivityAttributes: ActivityAttributes {}
#endif
