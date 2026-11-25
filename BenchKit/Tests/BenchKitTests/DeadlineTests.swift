import Foundation
import Testing
@testable import BenchKit

/// A time limit on a handshake. The quiet switch from the home network to
/// Tailscale relies on a handshake that finished in time staying open.
@Suite struct DeadlineTests {
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    @Test func workThatFinishesInTimeIsNotStopped() async {
        let stopped = Flag()
        let answer = await Deadline.first(within: .seconds(30)) {
            try? await Task.sleep(for: .milliseconds(20))
            return "welcome"
        } onTimeout: { stopped.set() }
        #expect(answer == "welcome")
        // Long enough for a cancelled wait to have run on, if it were going to.
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!stopped.isSet)
    }

    @Test func workThatTakesTooLongIsStopped() async {
        let stopped = Flag()
        let answer: String? = await Deadline.first(within: .milliseconds(30)) {
            try? await Task.sleep(for: .seconds(30))
            return nil
        } onTimeout: { stopped.set() }
        #expect(answer == nil)
        #expect(stopped.isSet)
    }
}
