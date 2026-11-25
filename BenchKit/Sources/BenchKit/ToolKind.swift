import Foundation

/// What a tool call is for, whichever agent made it.
///
/// Each agent has its own names for its tools. A transcript reader turns
/// them into the names below as it reads (`TranscriptMessage.toolName`
/// always holds one of these, or a name with no kind here), and everything
/// that draws or counts tool calls asks for the kind, never the name. The
/// names are the ones Claude Code uses, because they were the first, and
/// because phones already paired with a Mac expect them.
public enum ToolKind: Sendable, Hashable, CaseIterable {
    /// Running a shell command.
    case shell
    /// Changing part of a file.
    case edit
    /// Writing a whole file.
    case write
    case notebookEdit
    case read
    /// Searching inside files.
    case search
    /// Finding files by name.
    case find
    case webFetch
    case webSearch
    /// Starting a subagent.
    case agent
    /// Updating the agent's own to-do list.
    case checklist
    /// Asking you a multiple-choice question.
    case question
    /// Asking you to approve its plan.
    case planApproval

    /// The names a transcript reader may use for this kind. The first is
    /// the one to write.
    public var names: [String] {
        switch self {
        case .shell: ["Bash"]
        case .edit: ["Edit", "MultiEdit"]
        case .write: ["Write"]
        case .notebookEdit: ["NotebookEdit"]
        case .read: ["Read"]
        case .search: ["Grep"]
        case .find: ["Glob"]
        case .webFetch: ["WebFetch"]
        case .webSearch: ["WebSearch"]
        case .agent: ["Agent", "Task"]
        case .checklist: ["TodoWrite", "TaskCreate", "TaskUpdate", "TaskList", "TaskGet"]
        case .question: ["AskUserQuestion"]
        case .planApproval: ["ExitPlanMode"]
        }
    }

    /// The name a reader gives a call of this kind.
    public var name: String { names[0] }

    private static let byName: [String: ToolKind] = {
        var kinds: [String: ToolKind] = [:]
        for kind in allCases { for name in kind.names { kinds[name] = kind } }
        return kinds
    }()

    /// Nil for a tool with no kind of its own, like one from an MCP server.
    public init?(name: String?) {
        guard let name, let kind = Self.byName[name] else { return nil }
        self = kind
    }
}

extension TranscriptMessage {
    /// What kind of tool call this is, if it's one of the known kinds.
    public var tool: ToolKind? { ToolKind(name: toolName) }
}
