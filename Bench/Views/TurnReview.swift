import BenchKit
import Foundation

/// Reads a Claude tab's conversation for a turn's review, straight from
/// its transcript, so the review works whether or not the chat is open.
enum TurnReview {
    /// What a turn's review shows.
    enum Loaded: Equatable, Sendable {
        /// The tab has no conversation to read.
        case noConversation
        /// The turn asked for isn't in the part of the conversation read.
        case turnGone
        case turn(TurnChanges, ReviewDiff)
    }

    /// How much of the end of a long transcript is read. Turns worth
    /// reviewing are recent, and old tool output runs to hundreds of megabytes.
    nonisolated private static let tail: UInt64 = 8 << 20

    nonisolated private static let options = TranscriptParser.Options(keepsResults: true, keepsPatches: true)

    /// The turn with this id, or the latest for nil, from the transcript
    /// at `path`, with its changes laid out for reading. `root` is the
    /// project's folder.
    nonisolated static func load(path: String?, turnID: String?, root: String) -> Loaded {
        guard let path, let turns = turns(at: path) else { return .noConversation }
        let found = turnID.map { TurnChanges.turn($0, in: turns) } ?? TurnChanges.latest(in: turns)
        guard let found else { return turnID == nil ? .noConversation : .turnGone }
        return .turn(found, ReviewDiff(turn: found, root: root))
    }

    /// The end of a transcript as turns, or nil when it can't be read.
    nonisolated static func turns(at path: String) -> [TranscriptTurn]? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        let format = Agents.transcripts(for: path).format
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        let start = end > tail ? end - tail : 0
        try? handle.seek(toOffset: start)
        guard var data = try? handle.readToEnd() else { return nil }
        // Starting part-way through, the first line is only its end.
        if start > 0, let newline = data.firstIndex(of: UInt8(ascii: "\n")) {
            data = Data(data[data.index(after: newline)...])
        }
        var messages: [TranscriptMessage] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            // Pictures aren't needed here, and decoding them is most of the work.
            messages += format.messages(in: Data(line), options: options).map { message in
                var message = message
                message.images = []
                return message
            }
        }
        return TranscriptTurn.group(messages)
    }

    /// The size of the file at `path`, for noticing that it grew.
    nonisolated static func size(of path: String?) -> UInt64? {
        guard let path else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? UInt64
    }

    /// The Claude tab whose turn "the latest turn" means for a project:
    /// the one whose conversation was added to most recently, or failing
    /// that the first one.
    static func latestClaudeTab(in project: Project, terminals: TerminalManager) -> UUID? {
        let tabs = project.tabs.filter { $0.kind == .agent }
        let dated = tabs.compactMap { tab -> (UUID, Date)? in
            guard let path = CompanionSnapshots.transcriptPath(tabID: tab.id, terminals: terminals),
                  let changed = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return nil }
            return (tab.id, changed)
        }
        return dated.max { $0.1 < $1.1 }?.0 ?? tabs.first?.id
    }
}
