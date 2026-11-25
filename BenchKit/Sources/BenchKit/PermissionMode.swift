import Foundation

/// Claude Code's permission modes: how much it does before asking. Its
/// terminal shows the current one under the message box, like
/// "⏸ plan mode on", and Shift-Tab steps to the next.
public enum PermissionMode: String, CaseIterable, Sendable, Hashable {
    /// Asks before edits and commands. Claude Code calls it "manual mode";
    /// its settings call it "default".
    case manual
    case acceptEdits
    case plan
    case auto
    case bypass

    /// Its name in the picker.
    public var name: String {
        switch self {
        case .manual: "Ask first"
        case .acceptEdits: "Accept edits"
        case .plan: "Plan"
        case .auto: "Auto"
        case .bypass: "Bypass permissions"
        }
    }

    /// One line on what it does.
    public var detail: String {
        switch self {
        case .manual: "Asks before editing files or running commands"
        case .acceptEdits: "Edits files without asking, asks before commands"
        case .plan: "Explores and plans, changes nothing until you approve"
        case .auto: "Decides for itself, asks only when it's risky"
        case .bypass: "Never asks"
        }
    }

    public var symbol: String {
        switch self {
        case .manual: "hand.raised"
        case .acceptEdits: "pencil"
        case .plan: "list.bullet.clipboard"
        case .auto: "sparkles"
        case .bypass: "exclamationmark.shield"
        }
    }

    /// The modes to offer, in the order Shift-Tab steps through them.
    /// Bypass is always there: Claude Code only allows it in a session
    /// started with it, and switching says so when it isn't.
    public static let offered: [PermissionMode] = [.manual, .acceptEdits, .plan, .auto, .bypass]

    /// The mode Claude Code's terminal shows, from its screen text. nil
    /// when there's no mode line, like while a picker covers the footer.
    public init?(screen: String?) {
        guard let screen else { return nil }
        // The mode line is near the bottom; scan up from there.
        for line in screen.split(separator: "\n", omittingEmptySubsequences: true).reversed().prefix(12) {
            let text = line.lowercased()
            guard text.contains("⏵⏵") || text.contains("⏸") else { continue }
            if text.contains("plan mode on") { self = .plan; return }
            if text.contains("accept edits on") { self = .acceptEdits; return }
            if text.contains("auto mode on") { self = .auto; return }
            if text.contains("bypass permissions on") { self = .bypass; return }
            if text.contains("manual mode on") || text.contains("default mode on") { self = .manual; return }
        }
        return nil
    }
}
