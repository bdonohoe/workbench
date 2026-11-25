import Foundation
import OSLog

/// Timing marks for the companion's slow paths, for Instruments. Open the
/// "os_signpost" instrument and filter on the Companion category to see
/// how long decoding a frame, grouping a conversation, and laying out a
/// chat screen take.
public enum Perf {
    public static let signposter = OSSignposter(subsystem: "me.birchtree.Bench", category: "Companion")

    private static let log = Logger(subsystem: "me.birchtree.Bench", category: "Companion")

    /// Times a piece of work by name. Debug builds also log anything over
    /// a few milliseconds, for reading in Console without Instruments.
    public static func measure<T>(_ name: StaticString, _ work: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        #if DEBUG
        let started = ContinuousClock.now
        defer {
            let elapsed = (ContinuousClock.now - started).components
            let ms = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
            if ms >= 4 { log.debug("\(name, privacy: .public) took \(ms, format: .fixed(precision: 1)) ms") }
        }
        #endif
        return try work()
    }

    /// Marks a moment by name.
    public static func mark(_ name: StaticString) {
        signposter.emitEvent(name)
        #if DEBUG
        log.debug("\(name, privacy: .public)")
        #endif
    }
}
