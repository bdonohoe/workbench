import Foundation

/// Which coding agent a session runs: Claude Code today, with room for
/// others. It's saved with a tab and sent to the phone, so it's a plain
/// string that a version without a given agent can still read and skip.
public struct AgentID: RawRepresentable, Codable, Hashable, Sendable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let claude = AgentID("claude")
    public static let codex = AgentID("codex")
    /// The agent a session has when nothing says which: every session
    /// was Claude's before there were others.
    public static let standard = claude
}
