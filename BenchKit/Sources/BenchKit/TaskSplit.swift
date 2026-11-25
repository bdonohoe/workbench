import Foundation

/// A project Claude can match a task to.
public struct SplitProject: Codable, Sendable, Hashable {
    public var id: UUID
    public var name: String
    public var summary: String

    public init(id: UUID, name: String, summary: String) {
        self.id = id
        self.name = name
        self.summary = summary
    }
}

/// One task from a split message, for the user to review before it starts.
public struct DraftTask: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var projectID: UUID?
    public var unsure: String?
    public var prompt: String
    public var source: String
    public var branch: String

    public init(id: UUID = UUID(), projectID: UUID? = nil, unsure: String? = nil, prompt: String = "", source: String = "", branch: String = "") {
        self.id = id
        self.projectID = projectID
        self.unsure = unsure
        self.prompt = prompt
        self.source = source
        self.branch = branch
    }
}

/// Asks Claude to split one message into tasks, and reads the reply.
public enum TaskSplit {
    public struct ParseError: Error {}

    public static let instructions = #"""
    You split a developer's message into separate coding tasks, one per request, and match each task to one of their projects.

    You get the message, then their projects, each with its name and a short description.

    Rules:
    - One task per request. Never merge two requests, and never split one request into two. Two requests for the same project are two tasks.
    - Keep their words and meaning. Change only what's needed for the prompt to stand alone in a fresh coding session that already works inside that project: drop the project name and lead-ins like "In pitwall I want to", "Also in Bench" or "oh and", resolve words that point at other parts of the message, like "that" or "also", and fix obvious typos.
    - Never add requirements, steps, tests, approaches or acceptance criteria they didn't ask for.
    - Match a project only when the message makes it clear. If a request could belong to more than one project, or to none, set "project" to null and say why in "unsure", naming the likely projects.
    - Greetings, asides and anything that isn't a request produce no task.
    - "source" is their own words that the task came from, at most 120 characters.

    Reply with only JSON and no other text:
    {"tasks":[{"project":"<a project name exactly as listed, or null>","unsure":"<why, or null>","prompt":"<the cleaned-up request>","source":"<their words>"}]}
    """#

    public static func input(message: String, projects: [SplitProject]) -> String {
        let list = projects.map { "- \($0.name): \($0.summary.isEmpty ? "No description." : $0.summary)" }
        return "Message:\n\(message)\n\nProjects:\n" + list.joined(separator: "\n")
    }

    private struct Reply: Decodable {
        struct Item: Decodable {
            var project: String?
            var unsure: String?
            var prompt: String?
            var source: String?
        }
        var tasks: [Item]
    }

    public static func parse(_ reply: String, projects: [SplitProject]) throws -> [DraftTask] {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let decoded = try? JSONDecoder().decode(Reply.self, from: Data(reply[start...end].utf8))
        else { throw ParseError() }

        return decoded.tasks.compactMap { item in
            let prompt = (item.prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else { return nil }
            var task = DraftTask(
                unsure: item.unsure,
                prompt: prompt,
                source: item.source ?? "",
                branch: BranchNames.suggest(from: prompt)
            )
            if let name = item.project?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                let matches = projects.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
                if matches.count == 1 {
                    task.projectID = matches[0].id
                } else if matches.isEmpty {
                    task.unsure = "Claude suggested “\(name)”, which isn't one of your projects."
                } else {
                    task.unsure = "More than one of your projects is called “\(name)”."
                }
            }
            return task
        }
    }

    /// Gives repeat branch names in the same project a -2, -3, … suffix.
    public static func uniquingBranches(_ tasks: [DraftTask], existing: [UUID: Set<String>]) -> [DraftTask] {
        var used = existing
        return tasks.map { task in
            guard let project = task.projectID else { return task }
            var task = task
            let base = task.branch.trimmingCharacters(in: .whitespacesAndNewlines)
            var name = base
            var n = 2
            while used[project, default: []].contains(name) {
                name = "\(base)-\(n)"
                n += 1
            }
            used[project, default: []].insert(name)
            task.branch = name
            return task
        }
    }

    /// What stops each task from starting, keyed by task id. Empty means all ready.
    public static func problems(_ tasks: [DraftTask], existing: [UUID: Set<String>], names: [UUID: String]) -> [UUID: String] {
        var result: [UUID: String] = [:]
        var seen: [UUID: Set<String>] = [:]
        for task in tasks {
            guard let project = task.projectID else { result[task.id] = "Pick a project."; continue }
            let branch = task.branch.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = names[project] ?? "this project"
            if branch.isEmpty {
                result[task.id] = "Add a branch name."
            } else if task.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result[task.id] = "Write a prompt."
            } else if existing[project]?.contains(branch) == true {
                result[task.id] = "\(branch) already exists in \(name). Pick another branch name."
            } else if seen[project]?.contains(branch) == true {
                result[task.id] = "Another task in \(name) already uses \(branch)."
            }
            seen[project, default: []].insert(branch)
        }
        return result
    }

    /// The first paragraph of a README, as a short plain description.
    public static func brief(fromMarkdown text: String, limit: Int = 400) -> String {
        var lines: [String] = []
        var inFence = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inFence.toggle(); continue }
            if inFence { continue }
            if line.isEmpty {
                if !lines.isEmpty { break }
                continue
            }
            if ["#", "![", "[![", "<", ">", "|"].contains(where: line.hasPrefix) { continue }
            lines.append(line)
        }
        let joined = lines.joined(separator: " ")
        guard joined.count > limit else { return joined }
        let head = String(joined.prefix(limit + 1))
        guard let space = head.lastIndex(of: " ") else { return String(joined.prefix(limit)) + "…" }
        return String(head[..<space]) + "…"
    }
}
