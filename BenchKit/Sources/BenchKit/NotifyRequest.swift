import Foundation

/// What `bench notify` asks for: a notification on the Mac, paired phones,
/// or both, with a message and perhaps a title.
///
public struct NotifyRequest: Equatable, Sendable {
    public enum Target: String, Sendable {
        case both, mac, phone
    }

    /// The tab the command ran in, when Workbench started that tab.
    public var tabID: UUID?
    public var target: Target
    /// Nil when the command gave none, so the caller can pick one.
    public var title: String?
    public var message: String

    public init(tabID: UUID? = nil, target: Target = .both, title: String? = nil, message: String) {
        self.tabID = tabID
        self.target = target
        self.title = title
        self.message = message
    }

    /// Longer messages are cut: a notification shows a few lines at most,
    /// and a push payload has a hard size limit.
    public static let messageLimit = 1000

    /// The message as a notification can carry it, cut if it's too long.
    public static func trimmed(_ message: String) -> String? {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return nil }
        return message.count > messageLimit ? String(message.prefix(messageLimit - 1)) + "…" : message
    }
}
