import Foundation

/// One tool call, in words ("Editing Theme.swift"), and when Claude made it.
public struct ToolAction: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var text: String
    public var at: Date

    public init(id: String, text: String, at: Date) {
        self.id = id
        self.text = text
        self.at = at
    }

    /// "Edited Theme.swift" for a call that's finished.
    public var pastText: String { ToolWording.past(text) }
}

/// A subagent Claude started: what it's for, from the Agent tool's input.
public struct AgentCall: Codable, Sendable, Hashable {
    /// Claude's few words for the job, like "Find setup-specific assumptions".
    public var description: String
    /// The kind of agent, like "Explore" or "Plan". nil for the general one.
    public var type: String?
    /// True when Claude kept working while it ran.
    public var background: Bool

    public init(description: String, type: String? = nil, background: Bool = false) {
        self.description = description
        self.type = type
        self.background = background
    }
}

/// Claude Code's note that something running in the background stopped:
/// a subagent, or a command it left running.
public struct TaskNotice: Codable, Sendable, Hashable {
    /// The Agent or Bash call that started it.
    public var toolUseID: String?
    /// "completed", "failed", "killed", and so on.
    public var status: String

    public init(toolUseID: String?, status: String) {
        self.toolUseID = toolUseID
        self.status = status
    }

    public var failed: Bool { status == "failed" || status == "error" }
    public var stopped: Bool { status == "killed" || status == "stopped" || status == "cancelled" }

    /// Reads one from the tagged text Claude Code sends itself.
    static func parse(_ text: String) -> (TaskNotice, summary: String)? {
        guard text.hasPrefix("<task-notification>") else { return nil }
        func tag(_ name: String) -> String? {
            guard let start = text.range(of: "<\(name)>"), let end = text.range(of: "</\(name)>", range: start.upperBound..<text.endIndex)
            else { return nil }
            return String(text[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let status = tag("status") ?? "completed"
        let summary = tag("summary") ?? (status == "completed" ? "A background task finished" : "A background task stopped")
        return (TaskNotice(toolUseID: tag("tool-use-id"), status: status), summary)
    }
}

/// How a subagent is doing right now, from its own transcript.
public struct AgentStatus: Codable, Sendable, Hashable, Identifiable {
    /// The Agent call that started it.
    public var toolUseID: String
    public var description: String
    public var type: String?
    public var isFinished: Bool
    /// False once it's finished, or when it stopped without saying so.
    public var isRunning: Bool
    /// What it's doing now, in words ("Reading Theme.swift").
    public var action: String?
    /// Tool calls so far.
    public var steps: Int
    public var startedAt: Date?
    public var finishedAt: Date?

    public var id: String { toolUseID }

    public init(toolUseID: String, description: String, type: String? = nil, isFinished: Bool, isRunning: Bool,
                action: String? = nil, steps: Int = 0, startedAt: Date? = nil, finishedAt: Date? = nil) {
        self.toolUseID = toolUseID
        self.description = description
        self.type = type
        self.isFinished = isFinished
        self.isRunning = isRunning
        self.action = action
        self.steps = steps
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}
