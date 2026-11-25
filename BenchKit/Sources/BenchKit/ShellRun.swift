import Foundation

/// A command you ran yourself, by typing it with a leading `!` the way
/// Claude Code's own prompt runs one (`! make test`). Claude Code runs it
/// in the project's shell, shows you what it printed, and lets Claude see
/// that too, so Claude can carry on from the output without you pasting
/// it in. The transcript records the command and, once it has run, what
/// it printed, as two tagged user entries.
public struct ShellRun: Codable, Sendable, Hashable {
    /// The command, without the `!`.
    public var command: String
    /// What it printed, once it has run. Nil while it's still running.
    public var stdout: String?
    public var stderr: String?

    public init(command: String, stdout: String? = nil, stderr: String? = nil) {
        self.command = command
        self.stdout = stdout
        self.stderr = stderr
    }

    public var isFinished: Bool { stdout != nil }

    /// Everything it printed, errors last, trimmed of trailing blank lines.
    public var output: String {
        [stdout ?? "", stderr ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
            .trimmingCharacters(in: .newlines)
    }

    /// Printed to stderr and nothing else: most likely a failure.
    public var looksFailed: Bool {
        isFinished && (stdout ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !(stderr ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// How the command reads in a message: `! make test`.
    public var typed: String { "! " + command }

    /// The run a message you typed asks for: one that starts with `!`
    /// and has a command after it. Nil for an ordinary message.
    public static func typed(_ text: String) -> ShellRun? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("!") else { return nil }
        let command = trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return nil }
        return ShellRun(command: command)
    }

    /// The command in Claude Code's `<bash-input>` entry, or nil for
    /// anything else.
    public static func command(inTranscript text: String) -> String? {
        guard let inner = contents(of: "bash-input", in: text) else { return nil }
        return inner.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What a command printed, from Claude Code's `<bash-stdout>` and
    /// `<bash-stderr>` entry, or nil for anything else.
    public static func output(inTranscript text: String) -> (stdout: String, stderr: String)? {
        guard let stdout = contents(of: "bash-stdout", in: text) else { return nil }
        return (stdout, contents(of: "bash-stderr", in: text) ?? "")
    }

    private static func contents(of tag: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(tag)>"), let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex) else {
            return nil
        }
        return String(text[open.upperBound..<close.lowerBound])
    }
}
