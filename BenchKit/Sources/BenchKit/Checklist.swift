import Foundation

/// One line of the checklist Claude keeps while it works, as its terminal
/// shows it: done, the one in progress, or still to do.
public struct ChecklistItem: Codable, Sendable, Hashable, Identifiable {
    public enum Status: String, Codable, Sendable, Hashable {
        case pending, inProgress, completed

        public init(from decoder: Decoder) throws {
            // Anything a later version adds reads as still to do.
            self = Status(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .pending
        }
    }

    public var id: String
    /// "Add a lap time chart view".
    public var title: String
    /// "Adding a lap time chart view", shown while it's the current step.
    public var activeTitle: String?
    public var status: Status
    /// When Claude marked it in progress, if it did.
    public var startedAt: Date?

    public init(id: String, title: String, activeTitle: String? = nil, status: Status, startedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.activeTitle = activeTitle
        self.status = status
        self.startedAt = startedAt
    }

    /// The words for this line: the "-ing" form while it's under way.
    public var label: String {
        status == .inProgress ? (activeTitle ?? title) : title
    }
}

extension Array where Element == ChecklistItem {
    public var doneCount: Int { filter { $0.status == .completed }.count }

    /// The step under way, or the next one to do.
    public var current: ChecklistItem? {
        first { $0.status == .inProgress } ?? first { $0.status == .pending }
    }

    /// From 0 to 1.
    public var progress: Double { isEmpty ? 0 : Double(doneCount) / Double(count) }
}
