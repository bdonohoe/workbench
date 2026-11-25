import AppKit
import SwiftUI

/// `xcodebuild test` runs BenchTests inside this app, as its test host.
/// Left to itself, that copy would boot like the real thing: read the
/// saved tabs, join the session keeper and take over the terminals of the
/// Workbench you're using, sweep project folders, and start the companion.
/// So under the test harness the app opens nothing and starts nothing; the
/// tests build what they need.
enum TestHost {
    /// True when XCTest or Swift Testing is driving this process.
    nonisolated static let isRunning: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment.keys.contains { $0.hasPrefix("XCTest") } || NSClassFromString("XCTestCase") != nil
    }()
}

/// What runs in place of `BenchApp` under the test harness: a scene that
/// makes no window, so the run loop the tests need is up and nothing else.
struct TestHostApp: App {
    var body: some Scene {
        Settings { EmptyView() }
    }
}
