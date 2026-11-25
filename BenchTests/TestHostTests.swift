import AppKit
import Foundation
import Testing
@testable import Bench

/// The app these tests run inside must stay inert: it shares the real
/// Workbench's support folder and session keeper, and booting like the
/// real app would take over its terminals.
@MainActor
struct TestHostTests {
    @Test func theTestHostDoesNotActLikeTheApp() {
        #expect(TestHost.isRunning)
        #expect(!SessionKeeper.isActive)
        #expect(SessionKeeper.instance == nil)
        #expect(NSApp.windows.allSatisfy { !$0.isVisible })
    }
}
