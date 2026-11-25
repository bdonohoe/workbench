import Foundation
import Testing
@testable import BenchKit

@Test func readsEachModeFromTheFooter() {
    let box = "────────────────────────\n❯ \n────────────────────────\n"
    #expect(PermissionMode(screen: box + "  ⏸ manual mode on") == .manual)
    #expect(PermissionMode(screen: box + "  ⏵⏵ accept edits on (shift+tab to cycle) · ← 1 agent") == .acceptEdits)
    #expect(PermissionMode(screen: box + "  ⏸ plan mode on (shift+tab to cycle)") == .plan)
    #expect(PermissionMode(screen: box + "  ⏵⏵ auto mode on (shift+tab to cycle)") == .auto)
    #expect(PermissionMode(screen: box + "  ⏵⏵ bypass permissions on (shift+tab to cycle)\n  ◆ Haiku 5.5 ▏ proj") == .bypass)
}

@Test func noFooterNoMode() {
    #expect(PermissionMode(screen: "❯ hello\n? for shortcuts") == nil)
    #expect(PermissionMode(screen: nil) == nil)
    // Words in the conversation aren't the footer.
    #expect(PermissionMode(screen: "I'll turn plan mode on for you") == nil)
}

@Test func everyModeIsOffered() {
    #expect(PermissionMode.offered == PermissionMode.allCases)
}

@Test func olderMacsSendNoMode() throws {
    let json = #"{"id":"5A3A8A0B-6D0B-4B0E-9C59-3F3C9C6C3F11","title":"t","activity":"idle"}"#
    let session = try JSONDecoder().decode(CompanionSession.self, from: Data(json.utf8))
    #expect(session.permissionMode == nil)
}
