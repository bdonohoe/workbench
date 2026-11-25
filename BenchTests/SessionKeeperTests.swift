import Darwin
import Foundation
import Testing
@testable import Bench

/// Helper copies in Application Support: a Workbench clears out the ones
/// it doesn't use, except any another running Workbench has claimed.
@MainActor
struct SessionKeeperTests {
    @Test func aClaimedHelperSurvivesAnotherWorkbenchsCleanup() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bench-keeper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let claimed = "bench-session-aaaaaaaaaaaa", stale = "bench-session-bbbbbbbbbbbb", mine = "bench-session-cccccccccccc"
        for name in [claimed, stale, mine, "keeper.log"] {
            try Data("helper".utf8).write(to: folder.appendingPathComponent(name))
        }

        let claim = SessionKeeper.claim(folder.appendingPathComponent(claimed).path)
        #expect(claim >= 0)
        SessionKeeper.removeUnclaimedHelpers(in: folder, keeping: mine)

        let left = try Set(FileManager.default.contentsOfDirectory(atPath: folder.path))
        #expect(left == [claimed, mine, "keeper.log"])

        // Once the claim is let go, the copy is fair game.
        close(claim)
        SessionKeeper.removeUnclaimedHelpers(in: folder, keeping: mine)
        #expect(try Set(FileManager.default.contentsOfDirectory(atPath: folder.path)) == [mine, "keeper.log"])
    }

    /// A keeper from before you logged out and back in has to be replaced,
    /// but one that can't say which login it's from is left alone.
    @Test func onlyAKeeperFromAnotherLoginIsReplaced() {
        #expect(SessionKeeper.outlivedLogin(theirs: 100, mine: 200))
        #expect(!SessionKeeper.outlivedLogin(theirs: 100, mine: 100))
        #expect(!SessionKeeper.outlivedLogin(theirs: nil, mine: 100))
        #expect(!SessionKeeper.outlivedLogin(theirs: 100, mine: nil))
    }

    /// A real keeper says which login it's in, and a quit ends it and frees
    /// its socket for a new one.
    @Test func aKeeperReportsItsLoginAndQuitsWhenAsked() throws {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/bench-session").path
        guard FileManager.default.isExecutableFile(atPath: helper) else { return }
        let socket = (NSTemporaryDirectory() as NSString).appendingPathComponent("bk-\(UUID().uuidString.prefix(8)).sock")
        let keeper = Process()
        keeper.executableURL = URL(fileURLWithPath: helper)
        keeper.arguments = ["serve", "--socket", socket]
        keeper.standardError = FileHandle.nullDevice
        try keeper.run()
        defer { if keeper.isRunning { keeper.terminate() }; unlink(socket + ".lock") }

        var reply: KeeperWire.Reply?
        for _ in 0..<40 where reply == nil {
            usleep(50_000)
            reply = KeeperWire.ask(socket, .init(op: .list), timeout: 1)
        }
        #expect(reply?.ok == true)
        #expect(reply?.loginSession != nil)
        #expect(reply?.loginSession == KeeperWire.loginSession())

        #expect(KeeperWire.ask(socket, .init(op: .quit), timeout: 1)?.ok == true)
        for _ in 0..<40 where keeper.isRunning { usleep(50_000) }
        #expect(!keeper.isRunning)
        #expect(!FileManager.default.fileExists(atPath: socket))
    }
}
