import BenchKit
import Foundation
import Observation

/// A note on one line of a diff, waiting to be sent to Claude.
struct DiffComment: Identifiable, Hashable {
    let id = UUID()
    var path: String
    var oldNumber: Int?
    var newNumber: Int?
    /// The line's text, so the comment stays on the right line as the diff changes.
    var lineText: String
    var body: String

    init(path: String, line: DiffLine, body: String) {
        self.path = path
        oldNumber = line.oldNumber
        newNumber = line.newNumber
        lineText = line.text
        self.body = body
    }

    func belongs(to line: DiffLine) -> Bool {
        line.oldNumber == oldNumber && line.newNumber == newNumber && line.text == lineText
    }

    var location: String {
        if let newNumber { return "\(path):\(newNumber)" }
        if let oldNumber { return "\(path) (removed line \(oldNumber))" }
        return path
    }
}

/// Review comments for each project, kept until they're sent or discarded.
/// They live in memory only, like an unsent draft.
@Observable
final class ReviewComments {
    private var byProject: [UUID: [DiffComment]] = [:]

    func comments(for projectID: UUID) -> [DiffComment] { byProject[projectID] ?? [] }

    func add(_ comment: DiffComment, to projectID: UUID) {
        byProject[projectID, default: []].append(comment)
    }

    func remove(_ id: UUID, from projectID: UUID) {
        byProject[projectID]?.removeAll { $0.id == id }
    }

    func clear(_ projectID: UUID) {
        byProject[projectID] = nil
    }

    /// The message Claude receives.
    static func prompt(for comments: [DiffComment]) -> String {
        var text = "Please address these review comments on the current changes:\n"
        for (index, comment) in comments.enumerated() {
            text += "\n\(index + 1). \(comment.location)\n"
            let code = comment.lineText.trimmingCharacters(in: .whitespaces)
            if !code.isEmpty { text += "   > \(code)\n" }
            for line in comment.body.split(separator: "\n", omittingEmptySubsequences: false) {
                text += "   \(line)\n"
            }
        }
        return text
    }
}
