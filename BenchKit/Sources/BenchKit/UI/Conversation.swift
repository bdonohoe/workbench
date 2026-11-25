import Foundation
import Observation

/// A session's messages as turns, grouped once each time the messages
/// change rather than each time the screen draws, with the messages you
/// just sent merged in.
///
/// The chat screen used to call `TranscriptTurn.group` from its body, so
/// every change anywhere on the screen (the Mac's once-a-second snapshot,
/// a keystroke in the message box) regrouped the whole conversation.
@MainActor @Observable
public final class Conversation {
    /// The conversation as shown: the Mac's messages grouped, with your
    /// sent messages matched to theirs or waiting at the end.
    public private(set) var turns: [TranscriptTurn] = [] {
        didSet {
            sentTexts = ComposerHistory.entries(from: turns)
            if tracksChanges {
                let fresh = Dictionary(TurnChanges.all(in: turns).map { ($0.lastRowID, $0) }, uniquingKeysWith: { _, last in last })
                if fresh != changes { changes = fresh }
            }
        }
    }
    /// The files each turn changed, by the row they're listed under.
    /// Worked out once per change, like the turns, and only when asked for.
    public private(set) var changes: [String: TurnChanges] = [:]
    @ObservationIgnored private let tracksChanges: Bool
    /// The messages you sent, oldest first, worked out once per change for
    /// the message box's up arrow rather than on every draw.
    public private(set) var sentTexts: [String] = []
    /// False until the first messages have arrived, even if there are none.
    public private(set) var isLoaded = false

    private let outbox = Outbox()
    /// The Mac's messages grouped, before the outbox is merged in.
    @ObservationIgnored private var grouped: [TranscriptTurn] = []
    @ObservationIgnored private var messages: [TranscriptMessage]?

    /// `tracksChanges` also keeps `changes`, for a chat that lists each
    /// turn's changed files.
    public init(tracksChanges: Bool = false) {
        self.tracksChanges = tracksChanges
    }

    /// Gives the conversation the messages as they are now. Nothing happens
    /// when they're the same as last time; a quick check on their shape
    /// comes before comparing them all.
    public func update(_ messages: [TranscriptMessage]?) {
        guard let messages else {
            self.messages = nil
            grouped = []
            turns = []
            isLoaded = false
            return
        }
        if isLoaded, let old = self.messages, Shape(old) == Shape(messages), old == messages { return }
        self.messages = messages
        grouped = TranscriptTurn.group(messages)
        outbox.update(grouped)
        turns = outbox.merged(grouped)
        isLoaded = true
    }

    /// Shows a message you just sent, before the Mac's transcript has it.
    public func send(text: String, images: [Data], queued: Bool) {
        outbox.add(text: text, images: images, queued: queued, turns: grouped)
        turns = outbox.merged(grouped)
    }

    /// Takes the newest sent message back, as when it couldn't be sent.
    @discardableResult
    public func dropLastSent() -> Outbox.Pending? {
        let dropped = outbox.dropLast()
        turns = outbox.merged(grouped)
        return dropped
    }

    /// Whether a message you sent is still waiting for the Mac to show it.
    public var hasPendingSent: Bool { !outbox.pending.isEmpty }

    /// Gives up on sent messages that never arrived. Call a while after sending.
    public func settle() {
        outbox.update(grouped)
        turns = outbox.merged(grouped)
    }

    /// Enough about a message array to tell most changes apart cheaply.
    private struct Shape: Equatable {
        let count: Int
        let first: String?
        let last: String?

        init(_ messages: [TranscriptMessage]) {
            count = messages.count
            first = messages.first?.id
            last = messages.last?.id
        }
    }
}
