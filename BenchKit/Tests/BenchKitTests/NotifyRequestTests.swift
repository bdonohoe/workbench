import Foundation
import Testing
@testable import BenchKit

@Test func notifyMessagesAreTrimmed() {
    #expect(NotifyRequest.trimmed("  Tests passed\n") == "Tests passed")
    #expect(NotifyRequest.trimmed("line one\nline two") == "line one\nline two")
    #expect(NotifyRequest.trimmed("  \n ") == nil)
}

@Test func notifyCutsLongMessages() throws {
    let cut = try #require(NotifyRequest.trimmed(String(repeating: "a", count: 5000)))
    #expect(cut.count == NotifyRequest.messageLimit)
    #expect(cut.hasSuffix("…"))
}
