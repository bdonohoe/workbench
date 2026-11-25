import Foundation

/// The message box's shell mode. A draft that starts with `!` is a
/// command for the shell (see `ShellRun`). The box shows the `!` as a
/// chip beside the text instead of in it, so the draft keeps the whole
/// message (`! make test`) while the field holds only the command
/// (`make test`). The draft is what's saved, recalled and sent, so none
/// of that needs to know about the chip.
public enum ShellDraft {
    /// Whether the box is in shell mode for this draft.
    public static func isShell(_ draft: String) -> Bool { draft.hasPrefix("!") }

    /// What the field shows: the command without its `!`, or the whole
    /// draft for an ordinary message.
    public static func fieldText(for draft: String) -> String {
        guard isShell(draft) else { return draft }
        let rest = draft.dropFirst()
        return String(rest.hasPrefix(" ") ? rest.dropFirst() : rest)
    }

    /// How far a place in the field is from the same place in the draft,
    /// in UTF-16 units: the length of the hidden `! `.
    public static func hiddenPrefixLength(in draft: String) -> Int {
        draft.utf16.count - fieldText(for: draft).utf16.count
    }

    /// The draft for a command typed in shell mode.
    public static func draft(forCommand command: String) -> String { "! " + command }

    /// The draft after the field's text changed to `text`. In shell mode
    /// the text is the command, without any spaces typed before it out of
    /// habit (`! ls`). Otherwise it's the message, and one that now
    /// starts with `!` (pasted, say) turns into a command.
    public static func draft(afterEditing text: String, inShellMode: Bool) -> String {
        if inShellMode { return draft(forCommand: String(text.drop(while: { $0 == " " }))) }
        let lead = text.drop(while: \.isWhitespace)
        guard lead.hasPrefix("!") else { return text }
        return draft(forCommand: String(lead.dropFirst().drop(while: { $0 == " " })))
    }

    /// The draft once you leave shell mode: the command as a message.
    public static func leaving(_ draft: String) -> String { fieldText(for: draft) }

    /// A shell draft with no command yet, which there's nothing to send for.
    public static func isEmptyCommand(_ draft: String) -> Bool {
        isShell(draft) && fieldText(for: draft).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
