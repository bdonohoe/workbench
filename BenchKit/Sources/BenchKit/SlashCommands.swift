import Foundation

/// A slash command you can type to Claude Code: one of its own, one of
/// yours from `.claude/commands`, a skill, or one from a plugin.
public struct SlashCommand: Codable, Sendable, Hashable, Identifiable {
    public enum Source: String, Codable, Sendable {
        case builtIn, project, user, plugin
    }

    /// What follows the slash, like "compact" or "code-review:code-review".
    public var name: String
    public var description: String
    /// What it takes after its name, like "<model>" or "[instructions]".
    public var argumentHint: String?
    public var source: Source
    /// True for one that opens a picker or dialog in Claude Code's
    /// terminal, which a chat view can't show. The Mac's own chat handles
    /// some of these itself: see `ChatCommand`.
    public var opensInTerminal: Bool

    public var id: String { name }

    public init(name: String, description: String, argumentHint: String? = nil, source: Source,
                opensInTerminal: Bool = false) {
        self.name = name
        self.description = description
        self.argumentHint = argumentHint
        self.source = source
        self.opensInTerminal = opensInTerminal
    }

    // Lenient, so a phone and a Mac a version apart still understand each other.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        argumentHint = try c.decodeIfPresent(String.self, forKey: .argumentHint)
        source = (try? c.decodeIfPresent(Source.self, forKey: .source)) ?? .user
        opensInTerminal = try c.decodeIfPresent(Bool.self, forKey: .opensInTerminal) ?? false
    }

    /// What goes in the message box when it's picked.
    public var completion: String { "/\(name)" + (argumentHint != nil ? " " : "") }

    /// Claude Code's own commands that make sense to reach for by name.
    public static let builtIn: [SlashCommand] = [
        .init(name: "add-dir", description: "Let Claude work in another folder too", argumentHint: "<path>", source: .builtIn),
        .init(name: "agents", description: "See how to add or change subagents", source: .builtIn, opensInTerminal: true),
        .init(name: "btw", description: "Ask a side question without adding it to the conversation", argumentHint: "<question>", source: .builtIn),
        .init(name: "clear", description: "Start over with an empty conversation", source: .builtIn),
        .init(name: "code-review", description: "Review the current changes or a pull request for bugs", argumentHint: "[pr]", source: .builtIn),
        .init(name: "compact", description: "Summarize the conversation to free up context", argumentHint: "[what to keep]", source: .builtIn),
        .init(name: "config", description: "Open Claude Code's settings", source: .builtIn, opensInTerminal: true),
        .init(name: "context", description: "See what's filling the context window", source: .builtIn, opensInTerminal: true),
        .init(name: "doctor", description: "Check Claude Code's install for problems", source: .builtIn, opensInTerminal: true),
        .init(name: "effort", description: "Set how hard Claude thinks", argumentHint: "<low|medium|high|xhigh|max>", source: .builtIn),
        .init(name: "export", description: "Save this conversation as a text file", source: .builtIn, opensInTerminal: true),
        .init(name: "fast", description: "Turn fast mode on or off", source: .builtIn),
        .init(name: "help", description: "List every command", source: .builtIn, opensInTerminal: true),
        .init(name: "hooks", description: "Manage hooks", source: .builtIn, opensInTerminal: true),
        .init(name: "init", description: "Write a CLAUDE.md that describes this project", source: .builtIn),
        .init(name: "loop", description: "Run a prompt again on a schedule", argumentHint: "[interval] <prompt>", source: .builtIn),
        .init(name: "mcp", description: "Manage MCP servers", source: .builtIn, opensInTerminal: true),
        .init(name: "memory", description: "Edit Claude's memory files", source: .builtIn, opensInTerminal: true),
        .init(name: "model", description: "Switch the model", argumentHint: "<fable|opus|sonnet|haiku>", source: .builtIn),
        .init(name: "permissions", description: "Choose what Claude can do without asking", source: .builtIn, opensInTerminal: true),
        .init(name: "plugin", description: "Manage plugins", source: .builtIn, opensInTerminal: true),
        .init(name: "rename", description: "Name this conversation", argumentHint: "<name>", source: .builtIn),
        .init(name: "resume", description: "Pick up a past conversation", source: .builtIn, opensInTerminal: true),
        .init(name: "rewind", description: "Go back to an earlier point in the conversation", source: .builtIn, opensInTerminal: true),
        .init(name: "schedule", description: "Run a cloud agent on a schedule", argumentHint: "[what to do]", source: .builtIn),
        .init(name: "security-review", description: "Review this branch's changes for security problems", source: .builtIn),
        .init(name: "simplify", description: "Clean up the code you've changed", source: .builtIn),
        .init(name: "status", description: "See your account, model, and setup", source: .builtIn, opensInTerminal: true),
        .init(name: "usage", description: "See your plan's limits and what you've used", source: .builtIn, opensInTerminal: true),
    ]

    /// The commands matching what's typed after the slash: names that
    /// start with it first, then names with a word starting with it, then
    /// names that contain it. Nil when the text isn't a command being
    /// typed (no slash, or already past the name).
    public static func matches(for draft: String, in commands: [SlashCommand], limit: Int = 8) -> [SlashCommand]? {
        guard draft.hasPrefix("/"), !draft.contains(" "), !draft.contains("\n") else { return nil }
        return matches(query: String(draft.dropFirst()), in: commands, limit: limit)
    }
}

/// What the Mac's own chat does with one of Claude Code's commands that
/// would otherwise need its terminal. Other devices still leave these
/// out: what makes them work is on the Mac the session runs on.
public enum ChatCommand: Equatable, Sendable {
    /// Sent as typed. Claude Code prints its answer rather than opening
    /// anything, and the chat shows what it printed.
    case prints
    /// `/resume` with nothing after it: the project's past sessions, to
    /// pick one from. With a session named, Claude Code needs no picker.
    case resume
    /// `/usage` and its other names, `/cost` and `/stats`: Workbench's
    /// own Usage and Costs.
    case usage
    /// `/status`: the session's model, account and setup, in a card.
    case status
    /// `/help`: every command you can type, in a card.
    case help
    /// `/export` with nothing after it: asks where to save, then has
    /// Claude Code write the conversation there. With a file named,
    /// Claude Code needs no dialog.
    case export

    /// True for one the chat does itself rather than sending to Claude Code.
    public var runsInChat: Bool { self != .prints }

    /// The handling for a command by name, with what was typed after it.
    public init?(name: String, arguments: String = "") {
        switch name.lowercased() {
        case "context", "agents": self = .prints
        case "resume" where arguments.isEmpty: self = .resume
        case "usage", "cost", "stats": self = .usage
        case "status": self = .status
        case "help": self = .help
        case "export" where arguments.isEmpty: self = .export
        default: return nil
        }
    }

    /// The handling for a message that is just a command, like `/context all`.
    public init?(draft: String) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("/"), !text.contains("\n") else { return nil }
        let parts = text.dropFirst().split(separator: " ", maxSplits: 1).map(String.init)
        guard let name = parts.first else { return nil }
        self.init(name: name, arguments: parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : "")
    }
}

public extension SlashCommand {
    /// How the Mac's own chat handles it, for one of Claude Code's own.
    var chatCommand: ChatCommand? { source == .builtIn ? ChatCommand(name: name) : nil }

    /// The command as the Mac's own chat offers it: not marked for the
    /// terminal when the chat handles it.
    var inLocalChat: SlashCommand {
        guard opensInTerminal, chatCommand != nil else { return self }
        var copy = self
        copy.opensInTerminal = false
        return copy
    }
}
