import Foundation

/// How one agent writes its conversations to disk. Each agent's
/// command-line tool keeps a session as a file of JSON lines in a layout
/// of its own; a format reads a line into the messages the app shows,
/// which are the same whatever agent wrote them.
public protocol TranscriptFormat: Sendable {
    /// The messages in one line of a session file. Most lines hold none.
    func messages(in line: Data, options: TranscriptParser.Options) -> [TranscriptMessage]
}

/// Claude Code's session files (`TranscriptParser`).
public struct ClaudeTranscriptFormat: TranscriptFormat {
    public init() {}

    public func messages(in line: Data, options: TranscriptParser.Options) -> [TranscriptMessage] {
        TranscriptParser.messages(in: line, options: options)
    }
}
