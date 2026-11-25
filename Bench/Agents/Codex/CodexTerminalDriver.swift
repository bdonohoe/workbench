import BenchKit
import Foundation

/// Codex's terminal: its keys, its window title and what its screen looks
/// like. The screens this reads were captured from Codex 0.172.
nonisolated struct CodexTerminalDriver: AgentTerminalDriver {
    // MARK: Keys

    /// "Yes, proceed" is the option the cursor starts on.
    var allowKey: Key { .returnKey }
    /// Escape cancels the request and stops the turn, so Codex waits to
    /// hear what to do instead.
    var denyKey: Key { .escape }
    var interruptKey: Key { .escape }
    /// Codex takes a queued message when the turn ends, with no key to
    /// send it early or take it back.
    var sendQueueNowKey: Key? { nil }
    var nextModeKey: Key? { nil }
    var takesBackQueue: Bool { false }

    // MARK: The window title

    /// Codex spins a braille mark at the start of its title while it works.
    func isWorkingMark(_ scalar: Unicode.Scalar) -> Bool { (0x2800...0x28FF).contains(scalar.value) }

    /// Codex's title is the conversation's name and the folder's, which
    /// can't be told from a shell's. Its hooks say when it leaves.
    func titleIsAgents(_ title: String?) -> Bool { true }

    func titleIsStarting(_ title: String?) -> Bool { title?.hasPrefix("codex") == true }

    // MARK: The screen

    private static let placeholder = "Ask Codex to do anything"

    /// The message box and the line under it. The box is the last line
    /// starting with "›" that isn't a picker's choice, and under it is
    /// the status line ("GPT-6.2-Sol medium · ~/Apps/Recipes"). Nil when
    /// it isn't at the bottom of the screen, as after Codex quits.
    private func box(in screen: String?) -> (text: String, status: String)? {
        guard let screen else { return nil }
        var lines = screen.components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        guard let top = lines.lastIndex(where: { $0.hasPrefix("›") && $0.wholeMatch(of: #/›\s*\d+\.\s.*/#) == nil }) else { return nil }
        let below = Array(lines[(top + 1)...])
        guard let offset = below.firstIndex(where: { $0.hasPrefix("  ") && $0.contains(" · ") && !$0.hasPrefix("   ") }) else { return nil }
        // Only the hints line may follow the status line.
        guard below.count - offset <= 3 else { return nil }
        var inside = [String(lines[top].dropFirst())] + below[..<offset]
        inside = inside.map { $0.trimmingCharacters(in: .whitespaces) }
        let text = inside.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (text, below[offset].trimmingCharacters(in: .whitespaces))
    }

    func messageBox(in screen: String?) -> String? {
        guard let text = box(in: screen)?.text else { return nil }
        return text == Self.placeholder ? "" : text
    }

    func showsMessageBox(in screen: String?) -> Bool { box(in: screen) != nil }

    /// Codex has no `/effort`: effort is set through `/model`, for the
    /// session only.
    func typed(_ message: String) -> String {
        EffortLevel(command: message).map { "/model --reasoning=\($0.rawValue)" } ?? message
    }

    /// Codex takes Return that comes right behind fast typing for a line
    /// break in pasted text, so it has to come a little later.
    var returnDelay: Int { 600 }

    func isHint(_ box: String) -> Bool { box == Self.placeholder }
    func isQueueHint(_ box: String) -> Bool { false }
    func permissionMode(in screen: String?) -> PermissionMode? { nil }
    func planApproval(in screen: String?) -> CompanionQuestion? { nil }

    func startupPrompt(in screen: String) -> StartupPrompt? {
        let lines = screen.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        // Still asking, not left on screen: the key hints are the last line.
        guard let last = lines.last(where: { !$0.isEmpty }), last.hasPrefix("enter ") else { return nil }
        if let heading = lines.lastIndex(of: "Folder access"), lines.contains(where: { $0.hasPrefix("Trust this folder?") }) {
            // The path is under the heading, wrapped if it's long.
            let folder = lines[(heading + 1)...].drop { $0.isEmpty }.prefix { !$0.isEmpty && !$0.hasPrefix("Trust this folder?") }.joined()
            let name = folder.isEmpty ? "this folder" : (folder as NSString).abbreviatingWithTildeInPath
            let question = CompanionQuestion(
                question: "Do you trust the files in \(name)?",
                options: [.init(label: "Trust and continue", description: "Codex can read, edit and run files here. Only say yes for your own code or a project you know."),
                          .init(label: "Go back", description: "Codex leaves the folder and shows its list of sessions.")],
                allowsOther: false)
            return StartupPrompt(question: question, blocker: "is asking whether to trust this folder",
                                 answers: [.init(), .init(moves: [.downArrow], picked: "Back to")])
        }
        if lines.contains("Hooks need review"), lines.contains(where: { $0.contains("Trust all and continue") }) {
            let question = CompanionQuestion(
                question: "Let Codex run Workbench's hooks?",
                options: [.init(label: "Trust all and continue", description: "Hooks are how Workbench knows what Codex is doing: working, waiting for you, or done. Codex asks once and remembers. This trusts every hook it lists, including any from this project."),
                          .init(label: "Continue without trusting", description: "Codex runs, but Workbench can't follow it. The chat stays empty, so use the terminal.")],
                allowsOther: false)
            // The cursor starts on "Review hooks", the first of three.
            return StartupPrompt(question: question, blocker: "is asking you to review its hooks",
                                 answers: [.init(moves: [.downArrow], picked: "Trust all and continue"),
                                           .init(moves: [.downArrow, .downArrow], picked: "Continue without trusting")])
        }
        return nil
    }

    /// Codex's own multiple-choice questions aren't reported through its
    /// hooks, so there are no cards to answer.
    func answerSteps(questions: [CompanionQuestion], answers: [CompanionAnswer]) -> Result<[AnswerStep], AnswerProblem> {
        .failure(AnswerProblem(message: "Answer that in Codex's terminal."))
    }
}
