import BenchKit
import Foundation

nonisolated struct GitSnapshot: Sendable, Equatable {
    var branch: String?
    /// The ref being compared against (e.g. "origin/main").
    var baseRef: String?
    var staged: [FileChange] = []
    var unstaged: [FileChange] = []
    var againstBase: [FileChange] = []
    /// Commits on this branch that aren't on the base, newest first.
    var commits: [Commit] = []
    /// How this branch relates to the base: commits only here, commits only there.
    var aheadOfBase: Int?
    var behindBase: Int?
    /// When this branch split from the base (the merge-base commit's date).
    var forkedAt: Date?
    /// The tracking branch, like "origin/feat/x", if there is one.
    var upstream: String?
    var unpushed: Int?
    var unpulled: Int?
    /// When anything was last fetched into this repository.
    var lastFetch: Date?
    var isRepository = true
    var error: String?

    /// The upstream's remote name: "origin" for "origin/feat/x".
    var remoteName: String? { upstream?.split(separator: "/").first.map(String.init) }

    /// The same picture in the form the Changes panel and other devices
    /// use, with the branches to pick a base from.
    func changesSnapshot(branches: [String], chosenBase: String?) -> ChangesSnapshot {
        ChangesSnapshot(branch: branch, baseRef: baseRef, staged: staged, unstaged: unstaged,
                        againstBase: againstBase, commits: commits, isRepository: isRepository, error: error,
                        aheadOfBase: aheadOfBase, behindBase: behindBase, forkedAt: forkedAt, upstream: upstream,
                        unpushed: unpushed, unpulled: unpulled, lastFetch: lastFetch,
                        branches: Array(branches.prefix(40)), chosenBase: chosenBase)
    }
}

/// Runs git commands for one working copy. Everything here is off the main actor.
nonisolated struct GitClient: Sendable {
    let root: URL

    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    nonisolated func run(_ args: [String], okExitCodes: Set<Int32> = [0]) async throws -> Data {
        let root = root
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let git = Tools.git else {
                    continuation.resume(throwing: Failure(description: "git isn't installed. Install Apple's command line tools from Workbench's Setup settings."))
                    return
                }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: git)
                process.arguments = ["-c", "core.quotepath=off", "--no-optional-locks"] + args
                process.currentDirectoryURL = root
                var env = ProcessInfo.processInfo.environment
                env["GIT_TERMINAL_PROMPT"] = "0"
                env["LC_ALL"] = "C"
                process.environment = env
                let out = Pipe()
                let err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                // Read before waiting so large outputs can't fill the pipe and deadlock.
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if okExitCodes.contains(process.terminationStatus) {
                    continuation.resume(returning: data)
                } else {
                    let message = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: Failure(description: message.isEmpty ? "git \(args.first ?? "") failed" : message))
                }
            }
        }
    }

    nonisolated func string(_ args: [String]) async throws -> String {
        String(decoding: try await run(args), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated func optionalString(_ args: [String]) async -> String? {
        guard let value = try? await string(args), !value.isEmpty else { return nil }
        return value
    }

    // MARK: Refs

    nonisolated func currentBranch() async -> String? {
        if let branch = await optionalString(["symbolic-ref", "--short", "-q", "HEAD"]) { return branch }
        // Detached HEAD: show the short hash.
        return await optionalString(["rev-parse", "--short", "HEAD"])
    }

    /// The branch most repos treat as "main": origin's HEAD, then main, then master.
    nonisolated func defaultBase() async -> String? {
        if let remoteHead = await optionalString(["symbolic-ref", "--short", "-q", "refs/remotes/origin/HEAD"]) {
            return remoteHead
        }
        for candidate in ["main", "master", "origin/main", "origin/master", "develop"] {
            if await optionalString(["rev-parse", "--verify", "-q", candidate]) != nil { return candidate }
        }
        return nil
    }

    nonisolated func branches() async -> [String] {
        guard let output = await optionalString([
            "for-each-ref", "--sort=-committerdate", "--format=%(refname:short)", "refs/heads", "refs/remotes",
        ]) else { return [] }
        return output.split(separator: "\n").map(String.init).filter { !$0.hasSuffix("/HEAD") && $0 != "origin" }
    }

    nonisolated func mergeBase(_ base: String) async -> String? {
        await optionalString(["merge-base", base, "HEAD"])
    }

    // MARK: Snapshot

    nonisolated func snapshot(baseOverride: String?) async -> GitSnapshot {
        guard await optionalString(["rev-parse", "--is-inside-work-tree"]) == "true" else {
            return GitSnapshot(isRepository: false)
        }

        var snapshot = GitSnapshot()
        snapshot.branch = await currentBranch()

        do {
            let statusData = try await run(["status", "--porcelain=v1", "-z", "--untracked-files=all"])
            var status = Self.parseStatus(statusData)
            // An earlier Workbench left profiling data in this folder: take
            // it away rather than show it as a change.
            if status.unstaged.contains(where: { $0.kind == .untracked && $0.path == ProfrawLitter.fileName }),
               ProfrawLitter.sweep(root: root) {
                status.unstaged.removeAll { $0.path == ProfrawLitter.fileName }
            }

            async let unstagedStats = numstat(["diff", "--numstat", "-z", "-M"])
            async let stagedStats = numstat(["diff", "--cached", "--numstat", "-z", "-M"])
            let (unstagedNums, stagedNums) = await (unstagedStats, stagedStats)

            snapshot.staged = status.staged.map { change in
                var change = change
                if let stat = stagedNums[change.path] {
                    change.additions = stat.0
                    change.deletions = stat.1
                    change.isBinary = stat.2
                }
                return change
            }
            snapshot.unstaged = await withTaskGroup(of: FileChange.self) { group in
                for change in status.unstaged {
                    group.addTask {
                        var change = change
                        if change.kind == .untracked {
                            change.additions = Self.lineCount(root.appendingPathComponent(change.path))
                        } else if let stat = unstagedNums[change.path] {
                            change.additions = stat.0
                            change.deletions = stat.1
                            change.isBinary = stat.2
                        }
                        return change
                    }
                }
                var results: [FileChange] = []
                for await change in group { results.append(change) }
                return results.sorted { $0.path < $1.path }
            }
        } catch {
            snapshot.error = "\(error)"
        }

        let base: String? = if let baseOverride { baseOverride } else { await defaultBase() }
        snapshot.baseRef = base
        if let base, let mergeBase = await mergeBase(base) {
            let nums = await numstat(["diff", "--numstat", "-z", "-M", mergeBase, "HEAD"])
            let kinds = await nameStatus(["diff", "--name-status", "-z", "-M", mergeBase, "HEAD"])
            snapshot.againstBase = kinds.map { path, info in
                let stat = nums[path]
                return FileChange(
                    path: path, oldPath: info.oldPath, kind: info.kind,
                    additions: stat?.0 ?? 0, deletions: stat?.1 ?? 0, isBinary: stat?.2 ?? false,
                    section: .againstBase
                )
            }.sorted { $0.path < $1.path }
            snapshot.commits = await commits(range: "\(mergeBase)..HEAD")
            if let counts = await leftRightCounts("HEAD...\(base)") {
                snapshot.aheadOfBase = counts.left
                snapshot.behindBase = counts.right
            }
            if let stamp = await optionalString(["log", "-1", "--format=%ct", mergeBase]), let seconds = TimeInterval(stamp) {
                snapshot.forkedAt = Date(timeIntervalSince1970: seconds)
            }
        }
        if let upstream = await optionalString(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"]) {
            snapshot.upstream = upstream
            if let counts = await leftRightCounts("HEAD...@{u}") {
                snapshot.unpushed = counts.left
                snapshot.unpulled = counts.right
            }
        }
        snapshot.lastFetch = await lastFetchDate()
        return snapshot
    }

    /// "N\tM" from rev-list: commits only on the left side, only on the right.
    private nonisolated func leftRightCounts(_ range: String) async -> (left: Int, right: Int)? {
        guard let output = await optionalString(["rev-list", "--left-right", "--count", range]) else { return nil }
        let parts = output.split(whereSeparator: { $0 == "\t" || $0 == " " }).compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }

    /// FETCH_HEAD's modification date in the common git dir, so worktrees
    /// see the fetch their main checkout did.
    private nonisolated func lastFetchDate() async -> Date? {
        guard let common = await optionalString(["rev-parse", "--git-common-dir"]) else { return nil }
        let dir = common.hasPrefix("/") ? URL(fileURLWithPath: common) : root.appendingPathComponent(common)
        let fetchHead = dir.appendingPathComponent("FETCH_HEAD")
        return (try? FileManager.default.attributesOfItem(atPath: fetchHead.path))?[.modificationDate] as? Date
    }

    nonisolated func commits(range: String, limit: Int = 200) async -> [Commit] {
        // The separator comes first so each commit's --numstat lines, which git
        // prints after the formatted header, land in the same record.
        let format = "%x1e%H%x1f%h%x1f%s%x1f%b%x1f%an%x1f%ct%x1f"
        guard let data = try? await run(["log", "--format=\(format)", "--numstat", "-n", "\(limit)", range]) else { return [] }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\u{1e}")
            .compactMap { record in
                let fields = record.split(separator: "\u{1f}", omittingEmptySubsequences: false)
                guard fields.count >= 7, let seconds = TimeInterval(fields[5]) else { return nil }
                var commit = Commit(
                    hash: String(fields[0]), shortHash: String(fields[1]), subject: String(fields[2]),
                    body: fields[3].trimmingCharacters(in: .whitespacesAndNewlines),
                    author: String(fields[4]), date: Date(timeIntervalSince1970: seconds)
                )
                // Lines look like "12\t3\tpath". Binary files show "-" and are skipped.
                for line in fields[6].split(separator: "\n") {
                    let parts = line.split(separator: "\t", maxSplits: 2)
                    guard parts.count == 3 else { continue }
                    commit.additions += Int(parts[0]) ?? 0
                    commit.deletions += Int(parts[1]) ?? 0
                }
                return commit
            }
    }

    // MARK: Diffs

    /// The unified diff for one file in one section, with git's three
    /// unchanged lines around each change, or with `wholeFile` every
    /// unchanged line, so the diff view can fold them itself.
    nonisolated func diff(for change: FileChange, baseRef: String?, wholeFile: Bool = false) async -> String {
        let unified = wholeFile ? ["--unified=1000000"] : []
        var args: [String]
        switch change.section {
        case .unstaged:
            if change.kind == .untracked {
                // --no-index exits with 1 when the files differ, which is always here.
                let data = try? await run(["diff", "--no-index", "--no-color"] + unified + ["--", "/dev/null", change.path], okExitCodes: [0, 1])
                return data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            }
            args = ["diff"]
        case .staged:
            args = ["diff", "--cached"]
        case .againstBase:
            guard let baseRef, let mergeBase = await mergeBase(baseRef) else { return "" }
            args = ["diff", mergeBase, "HEAD"]
        }
        args += ["-M", "--no-color", "--no-ext-diff"] + unified + ["--"]
        if let old = change.oldPath { args.append(old) }
        args.append(change.path)
        return (try? await string(args)) ?? ""
    }

    /// Every file's diff in one commit (against its first parent, for a
    /// merge), or in the branch since it left `baseRef` when `commit` is nil.
    nonisolated func reviewDiff(commit: String?, baseRef: String?) async -> String {
        let common = ["-M", "--no-color", "--no-ext-diff"]
        if let commit {
            return (try? await string(["show", "--format=", "--diff-merges=first-parent"] + common + [commit, "--"])) ?? ""
        }
        guard let baseRef, let mergeBase = await mergeBase(baseRef) else { return "" }
        return (try? await string(["diff", mergeBase, "HEAD"] + common)) ?? ""
    }

    /// One commit's subject, message, author and date.
    nonisolated func commit(_ hash: String) async -> Commit? {
        guard let text = await optionalString(["show", "-s", "--format=%H%x00%h%x00%s%x00%an%x00%at%x00%b", hash, "--"]) else { return nil }
        let fields = text.components(separatedBy: "\u{0}")
        guard fields.count >= 6 else { return nil }
        return Commit(hash: fields[0], shortHash: fields[1], subject: fields[2],
                      body: fields[5].trimmingCharacters(in: .whitespacesAndNewlines), author: fields[3],
                      date: Date(timeIntervalSince1970: TimeInterval(fields[4]) ?? 0))
    }

    /// Just the changed lines of a file on disk, with no context, against
    /// HEAD, or against where the branch left `baseRef` when given. For
    /// marking changed lines in the file view.
    nonisolated func changedLines(_ path: String, baseRef: String?) async -> String {
        var from = "HEAD"
        if let baseRef, let mergeBase = await mergeBase(baseRef) { from = mergeBase }
        return (try? await string(["diff", from, "--unified=0", "--no-color", "--no-ext-diff", "--", path])) ?? ""
    }

    /// The file's contents before and after the change, for showing images.
    /// nil on a side means the file doesn't exist there (added or deleted).
    nonisolated func versions(for change: FileChange, baseRef: String?) async -> (old: Data?, new: Data?) {
        let oldPath = change.oldPath ?? change.path
        let oldRev: String?
        let newRev: String?
        switch change.section {
        case .unstaged:
            oldRev = change.kind == .untracked ? nil : ":"
            newRev = nil  // working copy, read from disk
        case .staged:
            oldRev = change.kind == .added ? nil : "HEAD:"
            newRev = ":"
        case .againstBase:
            guard let baseRef, let mergeBase = await mergeBase(baseRef) else { return (nil, nil) }
            oldRev = change.kind == .added ? nil : "\(mergeBase):"
            newRev = "HEAD:"
        }
        let old: Data? = if let oldRev { try? await run(["show", oldRev + oldPath]) } else { nil }
        let new: Data?
        if change.kind == .deleted {
            new = nil
        } else if let newRev {
            new = try? await run(["show", newRev + change.path])
        } else {
            new = try? Data(contentsOf: root.appendingPathComponent(change.path))
        }
        return (old, new)
    }

    // MARK: Parsing

    private nonisolated func numstat(_ args: [String]) async -> [String: (Int, Int, Bool)] {
        guard let data = try? await run(args) else { return [:] }
        return Self.parseNumstat(data)
    }

    private nonisolated func nameStatus(_ args: [String]) async -> [String: (kind: ChangeKind, oldPath: String?)] {
        guard let data = try? await run(args) else { return [:] }
        let fields = Self.nulFields(data)
        var result: [String: (ChangeKind, String?)] = [:]
        var i = 0
        while i < fields.count {
            let status = fields[i]
            guard let letter = status.first else { i += 1; continue }
            let kind = ChangeKind(letter: letter)
            if kind == .renamed || kind == .copied, i + 2 < fields.count {
                result[fields[i + 2]] = (kind, fields[i + 1])
                i += 3
            } else if i + 1 < fields.count {
                result[fields[i + 1]] = (kind, nil)
                i += 2
            } else {
                i += 1
            }
        }
        return result
    }

    private nonisolated static func nulFields(_ data: Data) -> [String] {
        data.split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
            .filter { !$0.isEmpty }
    }

    /// Parses `--numstat -z`. Renames come as "add\tdel\t" followed by old and new paths.
    nonisolated static func parseNumstat(_ data: Data) -> [String: (Int, Int, Bool)] {
        let fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var result: [String: (Int, Int, Bool)] = [:]
        var i = 0
        while i < fields.count {
            let parts = fields[i].split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { i += 1; continue }
            let binary = parts[0] == "-"
            let adds = Int(parts[0]) ?? 0
            let dels = Int(parts[1]) ?? 0
            if parts[2].isEmpty, i + 2 < fields.count {
                result[fields[i + 2]] = (adds, dels, binary)
                i += 3
            } else {
                result[String(parts[2])] = (adds, dels, binary)
                i += 1
            }
        }
        return result
    }

    /// Parses `status --porcelain=v1 -z` into staged and unstaged lists.
    nonisolated static func parseStatus(_ data: Data) -> (staged: [FileChange], unstaged: [FileChange]) {
        let fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var staged: [FileChange] = []
        var unstaged: [FileChange] = []
        var i = 0
        while i < fields.count {
            let entry = fields[i]
            i += 1
            guard entry.count >= 4 else { continue }
            let chars = Array(entry)
            let x = chars[0]
            let y = chars[1]
            let path = String(chars[3...])
            var oldPath: String?
            if x == "R" || x == "C" {
                oldPath = i < fields.count ? fields[i] : nil
                i += 1
            }

            if x == "?" {
                unstaged.append(FileChange(path: path, kind: .untracked, additions: 0, deletions: 0, section: .unstaged))
                continue
            }
            if x == "U" || y == "U" || (x == "A" && y == "A") || (x == "D" && y == "D") {
                unstaged.append(FileChange(path: path, kind: .conflicted, additions: 0, deletions: 0, section: .unstaged))
                continue
            }
            if x != " " {
                staged.append(FileChange(path: path, oldPath: oldPath, kind: ChangeKind(letter: x), additions: 0, deletions: 0, section: .staged))
            }
            if y != " " {
                unstaged.append(FileChange(path: path, kind: ChangeKind(letter: y), additions: 0, deletions: 0, section: .unstaged))
            }
        }
        return (staged.sorted { $0.path < $1.path }, unstaged)
    }

    /// Line count for an untracked file, skipping anything large or binary.
    nonisolated static func lineCount(_ url: URL) -> Int {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int, size < 5_000_000,
              let data = try? Data(contentsOf: url) else { return 0 }
        if data.prefix(8000).contains(0) { return 0 }
        var lines = data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        if let last = data.last, last != 0x0A { lines += 1 }
        return lines
    }
}
