import Foundation
import Observation

/// Messages you just sent, shown right away instead of after Claude Code
/// writes them to its transcript a moment later, the way a messaging app
/// shows your bubble the instant you hit send.
///
/// When the real message turns up, it takes over the sent bubble's
/// identity, so the bubble stays put instead of being swapped for a copy.
@MainActor @Observable
public final class Outbox {
    public struct Pending: Identifiable, Equatable {
        public let id: String
        public let text: String
        public let images: [TranscriptImage]
        /// Sent while Claude was busy, so it'll be queued.
        public let queued: Bool
        public let sentAt: Date
        /// User turns already there when it was sent; the real message is a new one.
        let known: Set<String>
        /// The text as `squeezed`, worked out once rather than on every poll.
        let words: String
    }

    public private(set) var pending: [Pending] = []
    /// Real turn ids that took over a sent bubble, and the bubble's id.
    private var aliases: [String: String] = [:]

    public init() {}

    /// Shows a message you just sent. `turns` is the conversation as it is now.
    public func add(text: String, images: [Data] = [], queued: Bool, turns: [TranscriptTurn]) {
        let id = "sent-" + UUID().uuidString
        let pictures = images.enumerated().map { TranscriptImage(id: "\(id)/\($0.offset)", mediaType: "image/png", data: $0.element) }
        pending.append(Pending(id: id, text: text, images: pictures, queued: queued, sentAt: .now,
                               known: Set(turns.filter(\.isUser).map(\.id)), words: Self.squeezed(text)))
    }

    /// Forgets the newest sent message, as when it couldn't be sent.
    @discardableResult
    public func dropLast() -> Pending? {
        pending.popLast()
    }

    /// The conversation with your sent messages in it: each one either
    /// matched to the real message, or at the end until that arrives.
    /// Doesn't change anything, so it's safe to call while drawing.
    public func merged(_ turns: [TranscriptTurn]) -> [TranscriptTurn] {
        let matches = match(turns)
        var result = turns.map { turn in
            guard let alias = aliases[turn.id] ?? matches[turn.id] else { return turn }
            return TranscriptTurn(id: alias, kind: turn.kind, results: turn.results)
        }
        let matched = Set(matches.values)
        for item in pending where !matched.contains(item.id) {
            // A `! command` shows as the command it is from the start,
            // rather than as a bubble that turns into one.
            let message = TranscriptMessage(id: item.id, role: .user, text: item.text, at: item.sentAt,
                                            images: item.images, queue: item.queued ? .added : nil,
                                            shell: ShellRun.typed(item.text))
            result.append(TranscriptTurn(id: item.id, kind: .user(message)))
        }
        return result
    }

    /// Settles sent messages that have arrived, and gives up on ones that
    /// never did. Call when the conversation changes.
    public func update(_ turns: [TranscriptTurn]) {
        let matches = match(turns)
        for (turnID, pendingID) in matches { aliases[turnID] = pendingID }
        let matched = Set(matches.values)
        let now = Date.now
        let left = pending.filter { !matched.contains($0.id) && now.timeIntervalSince($0.sentAt) < 30 }
        if left != pending { pending = left }
    }

    /// Which new user turn is which sent message, by their words.
    private func match(_ turns: [TranscriptTurn]) -> [String: String] {
        var result: [String: String] = [:]
        var taken = Set(aliases.keys)
        for item in pending {
            let words = item.words
            let found = turns.first { turn in
                guard turn.isUser, !taken.contains(turn.id), !item.known.contains(turn.id),
                      case .user(let message) = turn.kind else { return false }
                let theirs = Self.squeezed(message.text)
                return words.isEmpty ? !message.images.isEmpty || theirs.isEmpty : theirs == words
            }
            if let found {
                result[found.id] = item.id
                taken.insert(found.id)
            }
        }
        return result
    }

    /// Words without spacing or image tags, since the transcript can tidy those.
    private static func squeezed(_ text: String) -> String {
        let untagged = text.replacingOccurrences(of: #"\[Image(?: #\d+)?\]"#, with: "", options: .regularExpression)
        return String(untagged.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
    }
}

public extension TranscriptTurn {
    /// A message you sent, queued or not.
    var isUser: Bool {
        if case .user = kind { true } else { false }
    }
}
