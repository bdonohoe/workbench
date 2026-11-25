import Foundation

/// Finds the command line tools Bench uses (git, gh, claude, tailscale) the
/// way the user's own shell would. Apps opened from the Finder get a bare
/// PATH, so Bench asks the login shell for its PATH once at launch.
nonisolated enum Tools {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var shellPATH: [String]?
    nonisolated(unsafe) private static var gitWorks: Bool?
    nonisolated(unsafe) private static var resolved = false

    /// Where tools usually live, used until the shell answers (or if it can't).
    private static let fallback = [
        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
        NSHomeDirectory() + "/.local/bin", NSHomeDirectory() + "/.claude/local",
        "/opt/local/bin", "/run/current-system/sw/bin", NSHomeDirectory() + "/.nix-profile/bin",
    ]

    /// Asks the login shell for its PATH and checks for the developer tools.
    /// Call once, off the main thread, early in launch.
    static func resolve() {
        let path = askShellForPATH()
        lock.withLock {
            shellPATH = path
            resolved = true
        }
    }

    /// Resolves now unless that already happened.
    static func resolveIfNeeded() {
        if !lock.withLock({ resolved }) { resolve() }
    }

    /// The full path to `name`, or nil if it isn't installed.
    static func path(_ name: String) -> String? {
        let dirs = lock.withLock { shellPATH } ?? []
        var seen = Set<String>()
        for dir in dirs + fallback where seen.insert(dir).inserted {
            let candidate = (dir as NSString).appendingPathComponent(name)
            guard FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            // /usr/bin/git is a stub that pops up an install dialog when
            // Apple's command line tools are missing.
            if candidate == "/usr/bin/git", !appleGitWorks { continue }
            return candidate
        }
        return nil
    }

    /// This app's environment with the shell's PATH, for tools like gh that
    /// run other tools themselves.
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let dirs = lock.withLock { shellPATH } ?? []
        var seen = Set<String>()
        env["PATH"] = (dirs + fallback).filter { seen.insert($0).inserted }.joined(separator: ":")
        return env
    }

    /// git, or nil when using it would only bring up Apple's install dialog.
    static var git: String? { path("git") }

    private static func askShellForPATH() -> [String]? {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let marker = "__BENCH_PATH__"
        // Interactive and login, so both .zprofile and .zshrc (or their bash
        // and fish equivalents) get a chance to set PATH.
        guard let output = run(shell, ["-i", "-l", "-c", "printf '\(marker)%s\(marker)' \"$PATH\""], timeout: 5),
              let start = output.range(of: marker),
              let end = output.range(of: marker, range: start.upperBound..<output.endIndex)
        else { return nil }
        let value = output[start.upperBound..<end.lowerBound]
        // fish prints list variables with spaces.
        let separator: Character = value.contains(":") ? ":" : " "
        let dirs = value.split(separator: separator).map(String.init).filter { $0.hasPrefix("/") }
        return dirs.isEmpty ? nil : dirs
    }

    /// Checked once: whether /usr/bin/git runs without an install dialog.
    private static var appleGitWorks: Bool {
        if let known = lock.withLock({ gitWorks }) { return known }
        let works = developerToolsInstalled()
        lock.withLock { gitWorks = works }
        return works
    }

    /// Forgets the developer tools check, after the user installs them.
    static func recheck() {
        lock.withLock { gitWorks = nil }
        resolve()
    }

    /// True when /usr/bin/git can run without asking to install anything.
    private static func developerToolsInstalled() -> Bool {
        guard let dir = run("/usr/bin/xcode-select", ["-p"], timeout: 3)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !dir.isEmpty else { return false }
        return FileManager.default.isExecutableFile(atPath: dir + "/usr/bin/git")
    }

    /// Runs a program and returns what it printed, or nil if it failed or
    /// took longer than `timeout` seconds.
    /// With `requireSuccess` false, it returns the output even when the
    /// program exits with an error, for tools that report through both.
    static func run(_ executable: String, _ args: [String], timeout: TimeInterval = 10,
                    environment: [String: String]? = nil, requireSuccess: Bool = true) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        if let environment { process.environment = environment }
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        guard process.terminationReason == .exit, process.terminationStatus == 0 || !requireSuccess else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Runs a command line in the user's login shell, so it sees the same
    /// environment (API keys, provider settings) as a terminal tab does.
    static func runInShell(_ command: String, timeout: TimeInterval = 10, requireSuccess: Bool = true) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        return run(shell, ["-i", "-l", "-c", command], timeout: timeout, environment: environment, requireSuccess: requireSuccess)
    }
}
