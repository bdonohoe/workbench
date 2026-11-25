import Foundation

/// What the message box is doing for a draft. A draft that starts with
/// `!` is a shell command and one that starts with `/btw` is a side
/// question. Either way a chip stands for the prefix, and the field
/// holds only what comes after it.
public enum ComposerMode: Sendable, Equatable {
    case message, shell, sideQuestion
}

/// The message box's draft and what its field shows, for every mode. The
/// draft keeps the prefix (`! `, `/btw `), so sending, history and saved
/// drafts work as they always did.
public enum ComposerDraft {
    static let btw = "/btw"

    public static func mode(of draft: String) -> ComposerMode {
        if ShellDraft.isShell(draft) { return .shell }
        if startsSideQuestion(draft) { return .sideQuestion }
        return .message
    }

    /// `/btw`, in any case, then a space or nothing. `/btwx` is some
    /// other command.
    static func startsSideQuestion(_ text: some StringProtocol) -> Bool {
        guard text.lowercased().hasPrefix(btw) else { return false }
        return text.dropFirst(btw.count).first.map(\.isWhitespace) ?? true
    }

    /// What the field shows: the draft without its prefix, or the whole
    /// draft for an ordinary message.
    public static func fieldText(for draft: String) -> String {
        switch mode(of: draft) {
        case .shell: return ShellDraft.fieldText(for: draft)
        case .sideQuestion:
            let rest = draft.dropFirst(btw.count)
            return String(rest.first?.isWhitespace == true ? rest.dropFirst() : rest)
        case .message: return draft
        }
    }

    /// How far a place in the field is from the same place in the draft,
    /// in UTF-16 units: the length of the hidden prefix.
    public static func hiddenPrefixLength(in draft: String) -> Int {
        draft.utf16.count - fieldText(for: draft).utf16.count
    }

    /// The draft for a question typed in side question mode.
    public static func draft(forQuestion question: String) -> String { btw + " " + question }

    /// The draft after the field's text changed to `text`, in the mode the
    /// box was in. In a mode, the text is what follows the chip, without
    /// spaces typed before it out of habit. In a message, typing `!` or
    /// `/btw` at the start (or pasting it) switches to that mode.
    public static func draft(afterEditing text: String, in mode: ComposerMode) -> String {
        switch mode {
        case .shell: return ShellDraft.draft(afterEditing: text, inShellMode: true)
        case .sideQuestion: return draft(forQuestion: String(text.drop(while: { $0 == " " })))
        case .message:
            let lead = text.drop(while: \.isWhitespace)
            if lead.hasPrefix("!") { return ShellDraft.draft(afterEditing: text, inShellMode: false) }
            if startsSideQuestion(lead) {
                return draft(forQuestion: String(lead.dropFirst(btw.count).drop(while: \.isWhitespace)))
            }
            return text
        }
    }

    /// The draft once you leave a mode: what you typed, as a message.
    public static func leaving(_ draft: String) -> String { fieldText(for: draft) }

    /// A command or question with nothing typed after the chip yet, which
    /// there's nothing to send for.
    public static func isEmpty(_ draft: String) -> Bool {
        mode(of: draft) != .message && fieldText(for: draft).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
