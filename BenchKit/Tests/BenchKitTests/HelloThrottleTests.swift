import Foundation
import Testing
@testable import BenchKit

struct HelloThrottleTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func blocksOnTheFifthFailureWithinAMinute() {
        var throttle = HelloThrottle()
        for second in 0..<4 { throttle.failed(from: "10.0.0.5", at: start + Double(second * 10)) }
        #expect(!throttle.isBlocked("10.0.0.5", at: start + 40))
        throttle.failed(from: "10.0.0.5", at: start + 50)
        #expect(throttle.isBlocked("10.0.0.5", at: start + 50))
        // Only that address.
        #expect(!throttle.isBlocked("10.0.0.6", at: start + 50))
    }

    @Test func theBlockEndsAfterFiveMinutes() {
        var throttle = HelloThrottle()
        for _ in 0..<5 { throttle.failed(from: "10.0.0.5", at: start) }
        #expect(throttle.isBlocked("10.0.0.5", at: start + 299))
        #expect(!throttle.isBlocked("10.0.0.5", at: start + 300))
        // And it starts counting afresh: one more failure doesn't block again.
        throttle.failed(from: "10.0.0.5", at: start + 301)
        #expect(!throttle.isBlocked("10.0.0.5", at: start + 301))
    }

    @Test func failuresMoreThanAMinuteApartDontAddUp() {
        var throttle = HelloThrottle()
        for step in 0..<10 { throttle.failed(from: "10.0.0.5", at: start + Double(step * 61)) }
        #expect(!throttle.isBlocked("10.0.0.5", at: start + 9 * 61))
    }
}
