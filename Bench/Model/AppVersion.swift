import Foundation

/// Which build this is. The version and build number change with a
/// release; the commit changes with every build, which is what tells two
/// builds of the same version apart on a Mac that makes them all day. The
/// commit is stamped into Info.plist by the Bench target's post-build
/// script (project.yml), with a trailing "+" when the tree had changes
/// that weren't committed. The same script stamps how many commits the
/// build is past the public release, so a development build says it's
/// ahead of what everyone else runs.
struct AppVersion: Equatable {
    var version: String
    var build: String
    /// Short hash, or nil when the build had no git to ask.
    var commit: String?
    var isDebug: Bool
    /// Commits since the public release this build number belongs to:
    /// 0 for the release itself, nil when the build couldn't tell.
    var commitsSinceRelease: Int? = nil

    static let current: AppVersion = {
        let info = Bundle.main.infoDictionary
        var commit = info?["BenchGitCommit"] as? String
        if commit?.isEmpty == true || commit == "unknown" { commit = nil }
        #if DEBUG
        let debug = true
        #else
        let debug = false
        #endif
        return AppVersion(version: info?["CFBundleShortVersionString"] as? String ?? "?",
                          build: info?["CFBundleVersion"] as? String ?? "?",
                          commit: commit,
                          isDebug: debug,
                          commitsSinceRelease: (info?["BenchCommitsSinceRelease"] as? NSNumber)?.intValue)
    }()

    /// Past the public release: commits on top of it, or changes that
    /// weren't committed. A public build is never either.
    var isAheadOfRelease: Bool {
        (commitsSinceRelease ?? 0) > 0 || commit?.hasSuffix("+") == true
    }

    /// One short line for the foot of the sidebar: "0.8.4 (48) · d846160",
    /// then "12 ahead" on a build past the public release, and "Debug" on a
    /// development build. The public build adds nothing.
    var footer: String {
        var parts = ["\(version) (\(build))"]
        if let commit { parts.append(commit) }
        if let ahead = commitsSinceRelease, ahead > 0 { parts.append("\(ahead) ahead") }
        if isDebug { parts.append("Debug") }
        return parts.joined(separator: " · ")
    }

    /// In words, for Settings: "0.8.4 (build 48, commit d846160)".
    var long: String {
        var inside = "build \(build)"
        if let commit { inside += ", commit \(commit)" }
        if let ahead = commitsSinceRelease, ahead > 0 { inside += ", \(Self.commits(ahead)) past the release" }
        if isDebug { inside += ", debug" }
        return "\(version) (\(inside))"
    }

    /// The footer's tooltip.
    var help: String {
        var text = "Workbench \(version), build \(build)"
        if let commit {
            text += commit.hasSuffix("+")
                ? ", built from commit \(commit.dropLast()) with uncommitted changes"
                : ", built from commit \(commit)"
        }
        text += "."
        if let ahead = commitsSinceRelease {
            if ahead > 0 {
                text += " \(Self.commits(ahead)) ahead of the public release, \(version) (build \(build))."
            } else if isAheadOfRelease {
                text += " The public release, plus changes that weren't committed."
            } else {
                text += " The same code as the public release."
            }
        }
        if isDebug { text += " A development build." }
        return text + " Click for updates and what's new."
    }

    private static func commits(_ n: Int) -> String {
        n == 1 ? "1 commit" : "\(n) commits"
    }
}
