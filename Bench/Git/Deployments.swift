import AppKit
import Foundation
import Observation

/// Where a merged pull request's deploy stands, as the host (Railway,
/// Vercel, Netlify, Render, and others) reports it to GitHub.
nonisolated struct DeployInfo: Equatable, Sendable {
    enum State: Sendable { case deploying, succeeded, failed }

    var state: State
    var prNumber: Int
    var prTitle: String
    /// Each place the commit deploys to, like "birchfeed / production".
    var environments: [String]
    var failing: [String] = []
    /// The host's page for the deploy: its logs when it failed, the live
    /// site or dashboard otherwise.
    var url: URL?
    var finishedAt: Date?

    var summary: String {
        let places = environments.joined(separator: ", ")
        switch state {
        case .deploying: return "Deploying PR #\(prNumber) to \(places)"
        case .succeeded: return "PR #\(prNumber) deployed to \(places)"
        case .failed: return "PR #\(prNumber) failed to deploy to " + failing.joined(separator: ", ")
        }
    }
}

/// Follows a merged pull request's commit through its deploy, using the
/// GitHub Deployments that hosting services post for each commit they
/// deploy. Repos that never had a deployment are dropped after one look.
@Observable
final class Deployments {
    /// Keyed by the repo's own project (a worktree's parent), so the status
    /// stays visible after the merged worktree is cleaned up.
    private(set) var info: [UUID: DeployInfo] = [:]
    /// Called with the project's id and name when a deploy succeeds or fails.
    @ObservationIgnored var onFinished: ((UUID, String, DeployInfo) -> Void)?

    private struct Watch {
        var repo: String
        var sha: String
        var projectID: UUID
        var name: String
        var prNumber: Int
        var prTitle: String
        var started = Date.now
    }
    @ObservationIgnored private var watches: [String: Watch] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var timer: Timer?

    /// How long to wait for a host to start deploying the commit.
    private static let startWait: TimeInterval = 10 * 60
    /// How long a deploy can run before Bench stops following it.
    private static let runWait: TimeInterval = 45 * 60
    /// How long a finished deploy stays on the project's row.
    private static let shownSucceeded: TimeInterval = 15 * 60
    private static let shownFailed: TimeInterval = 60 * 60

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Starts following the deploy of a merged PR's commit.
    func watch(projectID: UUID, name: String, pr: PullRequestInfo) {
        guard let sha = pr.mergeCommit, let repo = Self.repo(from: pr.url), watches[sha] == nil else { return }
        watches[sha] = Watch(repo: repo, sha: sha, projectID: projectID, name: name, prNumber: pr.number, prTitle: pr.title)
        fetch(sha)
    }

    /// "owner/repo" from a pull request's address.
    nonisolated static func repo(from url: URL) -> String? {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2 else { return nil }
        return parts[0] + "/" + parts[1]
    }

    private func tick() {
        for sha in watches.keys { fetch(sha) }
        // Let finished deploys fade from the sidebar after a while.
        for (id, deploy) in info {
            guard let finished = deploy.finishedAt else { continue }
            let shown = deploy.state == .failed ? Self.shownFailed : Self.shownSucceeded
            if Date.now.timeIntervalSince(finished) > shown { info[id] = nil }
        }
    }

    private func fetch(_ sha: String) {
        guard let watch = watches[sha], !inFlight.contains(sha), let gh = PullRequests.ghPath else { return }
        inFlight.insert(sha)
        Task.detached(priority: .utility) {
            let result = Self.load(gh: gh, repo: watch.repo, sha: sha)
            await MainActor.run { [weak self] in
                self?.inFlight.remove(sha)
                self?.apply(result, to: watch)
            }
        }
    }

    private func apply(_ result: LoadResult, to watch: Watch) {
        let age = Date.now.timeIntervalSince(watch.started)
        switch result {
        case .failed:
            // gh couldn't answer this time (offline, rate limited). Try
            // again next tick, within the same time limits.
            if age > Self.runWait { stop(watch) }
        case .repoNeverDeploys:
            stop(watch)
        case .notStarted:
            if age > Self.startWait { stop(watch) }
        case .environments(let environments):
            var deploy = Self.summarize(environments, prNumber: watch.prNumber, prTitle: watch.prTitle)
            let old = info[watch.projectID]
            if deploy.state == .deploying {
                if age > Self.runWait {
                    stop(watch)
                    return
                }
            } else {
                deploy.finishedAt = .now
                watches[watch.sha] = nil
                onFinished?(watch.projectID, watch.name, deploy)
            }
            if old != deploy { info[watch.projectID] = deploy }
        }
    }

    private func stop(_ watch: Watch) {
        watches[watch.sha] = nil
        if info[watch.projectID]?.finishedAt == nil, info[watch.projectID]?.prNumber == watch.prNumber {
            info[watch.projectID] = nil
        }
    }

    // MARK: - Asking GitHub

    /// One place a commit deploys to, and its latest status.
    nonisolated struct Environment: Equatable, Sendable {
        var name: String
        /// pending, queued, in_progress, success, inactive, failure, or
        /// error. Nil before the host posts its first status.
        var state: String?
        var environmentURL: URL?
        var logURL: URL?
    }

    nonisolated enum LoadResult: Equatable, Sendable {
        case failed
        case repoNeverDeploys
        case notStarted
        case environments([Environment])
    }

    nonisolated static func summarize(_ environments: [Environment], prNumber: Int, prTitle: String) -> DeployInfo {
        let failing = environments.filter { ["failure", "error"].contains($0.state) }
        let running = environments.filter { !["failure", "error", "success", "inactive"].contains($0.state ?? "") }
        let state: DeployInfo.State = !failing.isEmpty ? .failed : !running.isEmpty ? .deploying : .succeeded
        let url = state == .failed
            ? failing.first.flatMap { $0.logURL ?? $0.environmentURL }
            : environments.lazy.compactMap { $0.environmentURL ?? $0.logURL }.first
        return DeployInfo(state: state, prNumber: prNumber, prTitle: prTitle,
                          environments: environments.map(\.name), failing: failing.map(\.name), url: url)
    }

    private nonisolated static func load(gh: String, repo: String, sha: String) -> LoadResult {
        guard let deployments = api(gh: gh, "repos/\(repo)/deployments?sha=\(sha)&per_page=30") as? [[String: Any]] else {
            return .failed
        }
        if deployments.isEmpty {
            // Hosts take a few seconds to pick up a push. Keep waiting only
            // if this repo has ever had a deploy.
            guard let any = api(gh: gh, "repos/\(repo)/deployments?per_page=1") as? [[String: Any]] else { return .failed }
            return any.isEmpty ? .repoNeverDeploys : .notStarted
        }
        // Newest first. A redeploy of the same commit replaces the older
        // one for that environment.
        var seen = Set<String>()
        var environments: [Environment] = []
        for deployment in deployments {
            guard let id = deployment["id"] as? Int else { continue }
            let name = deployment["environment"] as? String ?? "deploy"
            guard seen.insert(name).inserted else { continue }
            guard let statuses = api(gh: gh, "repos/\(repo)/deployments/\(id)/statuses?per_page=1") as? [[String: Any]] else {
                return .failed
            }
            environments.append(environment(name: name, status: statuses.first))
        }
        return .environments(environments)
    }

    nonisolated static func environment(name: String, status: [String: Any]?) -> Environment {
        func url(_ key: String) -> URL? {
            (status?[key] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
        }
        return Environment(name: name, state: status?["state"] as? String,
                           environmentURL: url("environment_url"), logURL: url("log_url") ?? url("target_url"))
    }

    private nonisolated static func api(gh: String, _ path: String) -> Any? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gh)
        process.arguments = ["api", path]
        process.environment = Tools.environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}
