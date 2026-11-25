import BenchKit
import Foundation

/// Asks Claude to split one message into tasks for your projects.
enum TaskSplitter {
    struct Failure: Error {
        var message: String
    }

    /// Where each project's repository is, for checking branch names.
    static func repos(in store: AppStore) -> [UUID: URL] {
        Dictionary(uniqueKeysWithValues: store.projects.map { ($0.id, $0.url) })
    }

    /// Real repositories only: worktrees are branches of those.
    static func projects(in store: AppStore) -> [SplitProject] {
        store.projects.compactMap { project in
            guard !project.isWorktree,
                  FileManager.default.fileExists(atPath: project.url.appendingPathComponent(".git").path)
            else { return nil }
            // The first file with a usable paragraph, so a bare README
            // doesn't hide CLAUDE.md.
            let summary = ["README.md", "CLAUDE.md"].lazy
                .compactMap { head(of: project.url.appendingPathComponent($0)) }
                .map { TaskSplit.brief(fromMarkdown: $0) }
                .first { !$0.isEmpty } ?? ""
            return SplitProject(id: project.id, name: project.name, summary: summary)
        }
    }

    /// The first 16 KB of a file, or nil if it can't be read.
    private static func head(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 16 * 1024) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// A message can span projects on different accounts, so this runs on
    /// the one account the caller picks.
    nonisolated static func split(_ message: String, projects: [SplitProject], repos: [UUID: URL] = [:],
                                  profile: ClaudeProfile) async -> Result<[DraftTask], Failure> {
        let reply = await Task.detached(priority: .userInitiated) {
            AgentRunner.run(TaskSplit.input(message: message, projects: projects),
                             instructions: TaskSplit.instructions, timeout: 60, profile: profile)
        }.value
        let text: String
        switch reply {
        case .success(let value): text = value
        case .failure(.notInstalled):
            return .failure(Failure(message: "Your agent isn't installed, so Workbench can't split your message. Install it, then try again."))
        case .failure(.timedOut):
            return .failure(Failure(message: "The agent took too long to answer. Try again."))
        case .failure(.couldNotStart), .failure(.failed):
            return .failure(Failure(message: "The agent couldn't split your message. Try again, or run it in a terminal to check you're signed in."))
        case .failure(.emptyReply):
            return .failure(Failure(message: "The agent's answer couldn't be read. Try again."))
        }
        let tasks: [DraftTask]
        do { tasks = try TaskSplit.parse(text, projects: projects) } catch {
            return .failure(Failure(message: "The agent's answer couldn't be read. Try again."))
        }
        // Branch names already taken in each project the tasks landed in.
        var existing: [UUID: Set<String>] = [:]
        for id in Set(tasks.compactMap(\.projectID)) {
            if let repo = repos[id] { existing[id] = await existingBranches(repo: repo) }
        }
        return .success(TaskSplit.uniquingBranches(tasks, existing: existing))
    }

    nonisolated static func existingBranches(repo: URL) async -> Set<String> {
        let output = await GitClient(root: repo).optionalString(["for-each-ref", "--format=%(refname:short)", "refs/heads"])
        return Set((output ?? "").split(separator: "\n").map(String.init))
    }
}
