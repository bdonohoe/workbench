import Foundation

/// A slash command you ran that prints something, like `/context`: the
/// command and what Claude Code printed for it. Claude Code shows that
/// only in its terminal. The transcript records the command and what it
/// printed as separate tagged entries; `TranscriptTurn.group` puts the
/// two together.
public struct CommandRun: Codable, Sendable, Hashable {
    /// What follows the slash, like "context". Empty on the entry that
    /// only holds what a command printed.
    public var name: String
    /// What was typed after the name.
    public var arguments: String
    /// What it printed. Nil on the entry that only names the command.
    public var output: String?
    /// True when `output` is Markdown rather than text laid out for a terminal.
    public var isMarkdown: Bool

    public init(name: String, arguments: String = "", output: String? = nil, isMarkdown: Bool = false) {
        self.name = name
        self.arguments = arguments
        self.output = output
        self.isMarkdown = isMarkdown
    }

    /// How the command reads in a message: `/context all`.
    public var typed: String { "/" + name + (arguments.isEmpty ? "" : " " + arguments) }

    /// Commands whose printed line says nothing the chat doesn't already
    /// show: the model pill covers "Set model to…", and so on.
    public static let quiet: Set<String> = ["model", "effort", "fast", "clear", "compact", "exit", "quit", "btw"]

    /// Commands that draw for the terminal and then record the same thing
    /// as Markdown. The chat waits for the Markdown.
    public static let recordsMarkdown: Set<String> = ["context"]

    /// True when what it printed is worth a card in the conversation.
    public var isShown: Bool {
        !Self.quiet.contains(name) && !(output ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The command in Claude Code's `<command-name>` entry, or nil for
    /// anything else.
    public static func command(inTranscript text: String) -> CommandRun? {
        guard let name = contents(of: "command-name", in: text)?.trimmingCharacters(in: .whitespacesAndNewlines),
              name.hasPrefix("/"), name.count > 1 else { return nil }
        let arguments = contents(of: "command-args", in: text)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return CommandRun(name: String(name.dropFirst()), arguments: arguments)
    }

    /// What a command printed, from Claude Code's `<local-command-stdout>`
    /// entry with the terminal's color codes taken out, or nil for
    /// anything else.
    public static func output(inTranscript text: String) -> String? {
        guard let printed = contents(of: "local-command-stdout", in: text) else { return nil }
        return printed.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .newlines)
    }

    /// The Markdown copy of what `/context` drew, which Claude Code
    /// records right after it, or nil for anything else.
    public static func markdownOutput(inTranscript text: String) -> String? {
        guard text.hasPrefix("## Context Usage") else { return nil }
        // Two spaces end a line in Markdown. Each of those lines gets its
        // own paragraph here, so the model and the tokens don't run together.
        return text.replacingOccurrences(of: "  \n", with: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func contents(of tag: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(tag)>"), let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex) else {
            return nil
        }
        return String(text[open.upperBound..<close.lowerBound])
    }
}
