import Foundation

/// What a coding agent offers in the chat: its models, its effort levels,
/// its quick commands, and which of the chat's features it has. The Mac
/// and the phone build their pickers and menus from this, so a control an
/// agent doesn't have isn't shown, and nothing has to ask which agent it is.
public struct AgentCatalog: Codable, Hashable, Sendable {
    public var models: [ModelChoice]
    /// Empty for an agent with no effort setting.
    public var efforts: [EffortLevel]
    public var quickCommands: [QuickCommand]
    public var features: Set<AgentFeature>

    public init(models: [ModelChoice], efforts: [EffortLevel], quickCommands: [QuickCommand], features: Set<AgentFeature>) {
        self.models = models
        self.efforts = efforts
        self.quickCommands = quickCommands
        self.features = features
    }

    public func has(_ feature: AgentFeature) -> Bool { features.contains(feature) }

    /// Claude Code's. Also what a session from a Mac that predates
    /// catalogs has, since every session then was Claude's.
    public static let claude = AgentCatalog(models: ModelChoice.all, efforts: EffortLevel.allCases,
                                            quickCommands: QuickCommand.allCases, features: Set(AgentFeature.allCases))

    // Anything a later version adds reads as absent, not as a failure.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        models = try c.decodeIfPresent([ModelChoice].self, forKey: .models) ?? []
        efforts = (try c.decodeIfPresent([String].self, forKey: .efforts) ?? []).compactMap(EffortLevel.init(rawValue:))
        quickCommands = (try c.decodeIfPresent([String].self, forKey: .quickCommands) ?? []).compactMap(QuickCommand.init(rawValue:))
        features = Set((try c.decodeIfPresent([String].self, forKey: .features) ?? []).compactMap(AgentFeature.init(rawValue:)))
    }
}

/// A part of the chat that only some agents have.
public enum AgentFeature: String, Codable, CaseIterable, Sendable {
    /// Multiple-choice questions shown as cards.
    case questionCards
    /// A plan shown for approval before the work starts.
    case planApproval
    /// Permission modes that can be switched from the chat.
    case permissionModes
    /// Side questions about the conversation so far.
    case sideQuestions
    /// Taking queued messages back, or sending them early.
    case queueEditing
    /// A suggested next message.
    case promptSuggestions
    /// Subagents shown with what each is doing.
    case subagents
    /// Pictures attached to a message.
    case pictures
    /// Published pages collected for the project.
    case artifacts
}

extension CompanionSession {
    /// What this session's agent offers. Claude's when the Mac didn't say.
    public var agentCatalog: AgentCatalog { catalog ?? .claude }
    /// What to call this session's agent: "Claude".
    public var agentTitle: String { agentName ?? "Claude" }
}
