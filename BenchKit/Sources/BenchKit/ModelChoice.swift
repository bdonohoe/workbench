import Foundation

/// A model you can switch a Claude session to from the chat view. Switching
/// types `/model <alias>` into Claude Code, the same as doing it by hand.
public struct ModelChoice: Identifiable, Hashable, Sendable, Codable {
    /// What `/model` takes, like "opus". Claude Code maps it to the latest.
    public let alias: String
    public let name: String
    /// What it's good for, in a list of models.
    public var summary: String = ""
    public var id: String { alias }

    public init(alias: String, name: String, summary: String = "") {
        self.alias = alias
        self.name = name
        self.summary = summary
    }

    public static let all = [
        ModelChoice(alias: "fable", name: "Fable", summary: "For the hardest problems"),
        ModelChoice(alias: "opus", name: "Opus", summary: "For complex work and everyday tasks"),
        ModelChoice(alias: "sonnet", name: "Sonnet", summary: "Quick and capable for simpler tasks"),
        ModelChoice(alias: "haiku", name: "Haiku", summary: "Fastest, for quick answers"),
    ]

    /// True for a message that's just `/model`, which opens a list of
    /// models to pick from, as it does in Claude Code's terminal.
    public static func opensPicker(_ draft: String) -> Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "/model"
    }

    /// The message that switches to it.
    public var command: String { "/model \(alias)" }

    /// True when a session's model, like "Opus 5.5", is this one.
    public func matches(_ model: String?) -> Bool {
        model?.lowercased().hasPrefix(name.lowercased()) ?? false
    }

    /// Fable costs the most: it has its own weekly limit on top of the
    /// plan's, and the highest API prices. The chat makes it stand out, so
    /// nobody stays on it by accident.
    public var usesLimitsFaster: Bool { alias == "fable" }

    /// The same, for a session's model like "Fable 5.1".
    public static func usesLimitsFaster(_ model: String?) -> Bool {
        all.first { $0.matches(model) }?.usesLimitsFaster ?? false
    }

    /// Haiku is the light one: a leaf beside its name in the model list.
    public var isEconomy: Bool { alias == "haiku" }

    /// Said next to a model that uses limits faster.
    public static let usesLimitsFasterNote = "Uses your limits faster"
    public static let usesLimitsFasterHelp = "Fable uses your weekly limits and API spend faster than other models."
}

/// How hard Claude thinks, as `/effort` sets it. Claude Code keeps one
/// for each model.
public enum EffortLevel: String, CaseIterable, Identifiable, Sendable, Codable {
    case low, medium, high, xhigh, max

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "Extra High"
        case .max: "Max"
        }
    }

    /// A shorter name, where five have to fit across a phone.
    public var shortName: String { self == .xhigh ? "X-High" : name }

    /// The message that sets it.
    public var command: String { "/effort \(rawValue)" }

    /// The level that many steps up (or down, when negative), stopping at
    /// the ends.
    public func stepped(_ steps: Int) -> EffortLevel {
        let all = Self.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[Swift.min(all.count - 1, Swift.max(0, index + steps))]
    }

    /// The level a message like `/effort high` sets, if it's one.
    public init?(command text: String) {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().split(separator: " ")
        guard parts.count == 2, parts[0] == "/effort", let level = EffortLevel(rawValue: String(parts[1])) else { return nil }
        self = level
    }
}

/// What the `/model` list asks for: a model, an effort level, or both.
/// The effort goes in after the model, since Claude Code keeps one per model.
public struct ModelRequest: Equatable, Sendable {
    public var model: ModelChoice?
    public var effort: EffortLevel?
    /// So asking for the same thing twice still counts as a change.
    private let id = UUID()

    public init(model: ModelChoice? = nil, effort: EffortLevel? = nil) {
        self.model = model
        self.effort = effort
    }
}

public extension CompanionSession {
    /// Its effort level, when the Mac knows it.
    var effortLevel: EffortLevel? { effort.flatMap(EffortLevel.init(rawValue:)) }

    /// Switching models and quick commands type into the terminal, so only
    /// while Claude can take a message and isn't in the middle of a turn.
    var canRunCommand: Bool {
        canReply && activity != .working && activity != .remoteWorking
    }
}

/// Claude Code commands you can run from the chat view without typing them.
public enum QuickCommand: String, CaseIterable, Identifiable, Sendable, Codable {
    case compact, clear

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .compact: "Compact Conversation"
        case .clear: "Clear Conversation…"
        }
    }

    public var symbol: String {
        switch self {
        case .compact: "arrow.down.right.and.arrow.up.left"
        case .clear: "eraser"
        }
    }

    /// What it does, for a tooltip or a hint.
    public var help: String {
        switch self {
        case .compact: "Summarizes the conversation so far to free up context"
        case .clear: "Starts over with an empty conversation"
        }
    }

    /// What gets typed into Claude Code.
    public var command: String { "/" + rawValue }

    /// Asks first, since there's no taking it back.
    public var confirmation: (title: String, message: String, button: String)? {
        switch self {
        case .compact: nil
        case .clear: ("Clear this conversation?", "The agent starts over with an empty conversation. The old one stays in Past Sessions.", "Clear")
        }
    }
}
