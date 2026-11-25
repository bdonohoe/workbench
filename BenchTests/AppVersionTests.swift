import Foundation
import Testing
@testable import Bench

/// The line at the foot of the sidebar, and the commit stamp behind it.
struct AppVersionTests {
    @Test func theFooterNamesVersionBuildAndCommit() {
        let release = AppVersion(version: "0.8.4", build: "48", commit: "d846160", isDebug: false)
        #expect(release.footer == "0.8.4 (48) · d846160")
        #expect(release.long == "0.8.4 (build 48, commit d846160)")

        let debug = AppVersion(version: "0.8.4", build: "48", commit: "d846160+", isDebug: true)
        #expect(debug.footer == "0.8.4 (48) · d846160+ · Debug")
        #expect(debug.help.contains("with uncommitted changes"))

        let noGit = AppVersion(version: "0.8.4", build: "48", commit: nil, isDebug: false)
        #expect(noGit.footer == "0.8.4 (48)")
        #expect(noGit.long == "0.8.4 (build 48)")
    }

    @Test func aBuildPastTheReleaseSaysHowFar() {
        let ahead = AppVersion(version: "0.9", build: "49", commit: "f86ba3d", isDebug: false, commitsSinceRelease: 12)
        #expect(ahead.footer == "0.9 (49) · f86ba3d · 12 ahead")
        #expect(ahead.long == "0.9 (build 49, commit f86ba3d, 12 commits past the release)")
        #expect(ahead.help.contains("12 commits ahead of the public release, 0.9 (build 49)."))
        #expect(ahead.isAheadOfRelease)

        let one = AppVersion(version: "0.9", build: "49", commit: "f86ba3d", isDebug: true, commitsSinceRelease: 1)
        #expect(one.footer == "0.9 (49) · f86ba3d · 1 ahead · Debug")
        #expect(one.help.contains("1 commit ahead"))
    }

    /// The public build looks the same as it always has.
    @Test func theReleaseItselfAddsNothingToTheFooter() {
        let release = AppVersion(version: "0.9", build: "49", commit: "f86ba3d", isDebug: false, commitsSinceRelease: 0)
        #expect(release.footer == "0.9 (49) · f86ba3d")
        #expect(release.long == "0.9 (build 49, commit f86ba3d)")
        #expect(release.help.contains("The same code as the public release."))
        #expect(!release.isAheadOfRelease)

        let dirty = AppVersion(version: "0.9", build: "49", commit: "f86ba3d+", isDebug: false, commitsSinceRelease: 0)
        #expect(dirty.isAheadOfRelease)
        #expect(dirty.help.contains("plus changes that weren't committed"))

        let unknown = AppVersion(version: "0.9", build: "49", commit: "f86ba3d", isDebug: false)
        #expect(!unknown.help.contains("public release"))
    }

    /// The build script stamped this very app, the one the tests run in.
    @Test func theBuildIsStampedWithItsCommit() {
        let current = AppVersion.current
        #expect(current.version != "?")
        #expect(current.build != "?")
        let commit = current.commit ?? ""
        let hash = commit.hasSuffix("+") ? String(commit.dropLast()) : commit
        #expect(hash.count >= 7, "commit was \(commit)")
        #expect(hash.allSatisfy { $0.isHexDigit }, "commit was \(commit)")
        #expect((current.commitsSinceRelease ?? -1) >= 0, "no distance from the release was stamped")
    }
}
