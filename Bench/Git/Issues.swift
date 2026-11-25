import BenchKit
import Foundation

/// A repo's open GitHub issues, asked of the GitHub CLI (`gh`) the same way
/// pull requests are: no account to connect, and a repo that isn't on
/// GitHub, or a Mac without `gh`, simply has none.
enum GitHubIssues {
    /// The last answer for each repo, so the New Agent sheet can offer
    /// issues the moment it opens while a fresh list loads.
    @MainActor private static var cache: [URL: [GitHubIssue]] = [:]

    @MainActor static func cached(repo: URL) -> [GitHubIssue] {
        cache[repo.standardizedFileURL] ?? []
    }

    /// The repo's open issues, newest first. Empty when there are none or
    /// GitHub couldn't be asked; a failure keeps the last list.
    @MainActor static func load(repo: URL) async -> [GitHubIssue] {
        let key = repo.standardizedFileURL
        let data = await Task.detached(priority: .userInitiated) {
            run(["issue", "list", "--state", "open", "--limit", "200", "--json", GitHubIssue.jsonFields], in: repo)
        }.value
        guard let data else { return cache[key] ?? [] }
        let issues = GitHubIssue.parseList(data)
        cache[key] = issues
        return issues
    }

    /// One issue by number, open or not, for `bench agent --issue`.
    static func issue(_ number: Int, repo: URL) async -> GitHubIssue? {
        await Task.detached(priority: .userInitiated) {
            run(["issue", "view", "\(number)", "--json", GitHubIssue.jsonFields], in: repo).flatMap(GitHubIssue.parseOne)
        }.value
    }

    /// What `gh` printed, or nil when it isn't installed or exited
    /// non-zero (no GitHub remote, no login, no such issue).
    private nonisolated static func run(_ arguments: [String], in root: URL) -> Data? {
        guard let gh = PullRequests.ghPath else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gh)
        process.arguments = arguments
        process.currentDirectoryURL = root
        process.environment = Tools.environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}
