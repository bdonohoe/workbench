import Foundation

/// The messages you've sent in a conversation, stepped through from the
/// message box with the up and down arrows, the way a shell recalls
/// commands. Up puts the newest one in the box, up again the one before,
/// and down comes back; past the newest, down gives back what you had
/// typed. Typing anything else leaves the history where it was.
public struct ComposerHistory: Equatable {
    /// Oldest first.
    public private(set) var entries: [String]
    /// Which entry is in the box, or nil while the box holds your own draft.
    public private(set) var position: Int?
    /// The text last put in the box, so a change made by typing can be told
    /// from one made here.
    public private(set) var recalled: String?
    /// What was in the box before the first up, kept for coming back down.
    private var stash = ""

    public init(entries: [String] = []) {
        self.entries = entries
    }

    /// Whether an entry is in the box right now.
    public var isBrowsing: Bool { position != nil }

    /// Your messages from `turns`, trimmed, oldest first. Blank ones and a
    /// message that repeats the one before it are left out.
    public static func entries(from turns: [TranscriptTurn]) -> [String] {
        var entries: [String] = []
        for turn in turns {
            guard case .user(let message) = turn.kind else { continue }
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text != entries.last else { continue }
            entries.append(text)
        }
        return entries
    }

    /// Takes the conversation's current messages. While an entry is in the
    /// box, it stays put: the position moves with it if the list grew.
    public mutating func update(entries new: [String]) {
        guard new != entries else { return }
        if let position, let recalled, entries.indices.contains(position) {
            // Keep pointing at the same message, wherever it is now.
            self.position = new.lastIndex(of: recalled)
            if self.position == nil { self.recalled = nil }
        }
        entries = new
    }

    /// The text to put in the box for an up arrow, or nil when there's
    /// nothing earlier to show. `draft` is what the box holds now.
    public mutating func up(from draft: String) -> String? {
        guard !entries.isEmpty else { return nil }
        if let position {
            guard position > 0 else { return nil }
            self.position = position - 1
        } else {
            stash = draft
            position = entries.count - 1
        }
        recalled = entries[position!]
        return recalled
    }

    /// The text to put in the box for a down arrow, or nil when the box
    /// already holds your own draft.
    public mutating func down() -> String? {
        guard let position else { return nil }
        if position + 1 < entries.count {
            self.position = position + 1
            recalled = entries[position + 1]
        } else {
            self.position = nil
            recalled = stash
        }
        return recalled
    }

    /// Tells the history the box changed. A change to anything but the
    /// text it put there means you're typing, and browsing is over.
    public mutating func draftChanged(to draft: String) {
        guard draft != recalled else { return }
        position = nil
        recalled = nil
    }
}
