import CryptoKit
import Foundation
import Testing
@testable import BenchKit

@Suite struct QueueSealTests {
    let token = "pairing-token"

    func prompt(_ text: String = "Fix it") -> QueuedPrompt {
        QueuedPrompt(id: UUID(), projectID: UUID(), projectName: "Bench", prompt: text,
                     queuedAt: Date(timeIntervalSince1970: 1_800_000_000), device: "Matt's iPhone")
    }

    func bytes(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

    @Test func mailboxIDIsStableHex() {
        let id = QueueSeal.mailboxID(token: token)
        #expect(id == QueueSeal.mailboxID(token: token))
        #expect(id.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil)
    }

    @Test func differentTokensDifferentMailboxes() {
        #expect(QueueSeal.mailboxID(token: "one") != QueueSeal.mailboxID(token: "two"))
    }

    @Test func keyDiffersFromNotificationKey() {
        #expect(bytes(QueueSeal.key(token: token)) != bytes(NotificationSeal.key(token: token, host: "mac")))
    }

    @Test func roundTripsUnicodeExactly() throws {
        let text = "Fix the 🐛 in café — “quotes”\nline 2" + String(repeating: "x", count: 20_000)
        let mailbox = QueueSeal.mailboxID(token: token)
        let key = QueueSeal.key(token: token)
        let original = prompt(text)
        let sealed = try QueueSeal.seal(original, key: key, mailbox: mailbox)
        #expect(QueueSeal.open(sealed, key: key, mailbox: mailbox) == original)
    }

    @Test func wrongKeyFails() throws {
        let mailbox = QueueSeal.mailboxID(token: token)
        let sealed = try QueueSeal.seal(prompt(), key: QueueSeal.key(token: token), mailbox: mailbox)
        #expect(QueueSeal.open(sealed, key: QueueSeal.key(token: "other"), mailbox: mailbox) == nil)
    }

    @Test func wrongMailboxFails() throws {
        let key = QueueSeal.key(token: token)
        let sealed = try QueueSeal.seal(prompt(), key: key, mailbox: QueueSeal.mailboxID(token: token))
        #expect(QueueSeal.open(sealed, key: key, mailbox: QueueSeal.mailboxID(token: "other")) == nil)
    }

    @Test func projectDecodesWithoutIsGit() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"Bench","repoName":"Bench","path":"/tmp/bench","activity":"idle","sessions":[]}
        """
        let project = try CompanionCoding.decoder.decode(CompanionProject.self, from: Data(json.utf8))
        #expect(project.isGit == nil)
    }
}
