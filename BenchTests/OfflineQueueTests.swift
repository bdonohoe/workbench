import BenchKit
import Foundation
import Synchronization
import Testing
@testable import Bench

/// Prompts queued on the phone while the Mac slept: taken from the relay,
/// opened, saved, then started oldest first. Anything that can't start
/// is kept with a reason.
@MainActor
struct OfflineQueueTests {
    private nonisolated static let token = "test-pairing-token"
    private static let relay = URL(string: "https://relay.test/api/queue")!

    /// A relay in memory. `take` moves what's waiting into claimed and
    /// hands back everything claimed; `ack` clears those ids from claimed.
    /// Records each request body.
    private nonisolated final class StubRelay: @unchecked Sendable {
        private let lock = NSLock()
        private var _items: [String: [QueueItem]] = [:]
        private var _claimed: [String: [QueueItem]] = [:]
        private var _bodies: [[String: Any]] = []
        private var _fails = false
        private var _loseTakes = 0
        private var _failAcks = 0
        private var _onAck: (@Sendable ([UUID]) -> Void)?

        var fails: Bool {
            get { lock.withLock { _fails } }
            set { lock.withLock { _fails = newValue } }
        }
        /// How many take answers to lose after the relay has done the take.
        var loseTakes: Int {
            get { lock.withLock { _loseTakes } }
            set { lock.withLock { _loseTakes = newValue } }
        }
        /// How many acks to fail before letting them through.
        var failAcks: Int {
            get { lock.withLock { _failAcks } }
            set { lock.withLock { _failAcks = newValue } }
        }
        /// Runs when an ack arrives, before it's answered.
        var onAck: (@Sendable ([UUID]) -> Void)? {
            get { lock.withLock { _onAck } }
            set { lock.withLock { _onAck = newValue } }
        }
        var bodies: [[String: Any]] { lock.withLock { _bodies } }
        func actions(_ name: String) -> [[String: Any]] { bodies.filter { $0["action"] as? String == name } }

        /// Seals with `sealedWith`'s key, to stand in for a prompt from
        /// another pairing code that can't be opened.
        func add(_ prompt: QueuedPrompt, token: String = OfflineQueueTests.token, sealedWith: String? = nil) throws {
            let mailbox = QueueSeal.mailboxID(token: token)
            let sealed = try QueueSeal.seal(prompt, key: QueueSeal.key(token: sealedWith ?? token), mailbox: mailbox)
            lock.withLock { _items[mailbox, default: []].append(QueueItem(id: prompt.id, sealed: sealed, addedAt: prompt.queuedAt)) }
        }

        private enum Outcome { case fail, ok, items([QueueItem]) }

        var transport: QueueRelay.Transport {
            { [self] request in
                let body = (request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
                let ids = (body["ids"] as? [String] ?? []).compactMap(UUID.init(uuidString:))
                let mailbox = body["mailbox"] as? String ?? ""
                let (outcome, ackHook) = lock.withLock { () -> (Outcome, (@Sendable ([UUID]) -> Void)?) in
                    _bodies.append(body)
                    if _fails { return (.fail, nil) }
                    switch body["action"] as? String {
                    case "take":
                        var claimed = _claimed[mailbox] ?? []
                        for item in _items[mailbox] ?? [] where !claimed.contains(where: { $0.id == item.id }) { claimed.append(item) }
                        _claimed[mailbox] = claimed
                        _items[mailbox] = []
                        if _loseTakes > 0 {
                            _loseTakes -= 1
                            return (.fail, nil)
                        }
                        return (.items(claimed), nil)
                    case "ack":
                        if _failAcks > 0 {
                            _failAcks -= 1
                            return (.fail, nil)
                        }
                        _claimed[mailbox]?.removeAll { ids.contains($0.id) }
                        return (.ok, _onAck)
                    default:
                        return (.ok, nil)
                    }
                }
                ackHook?(ids)
                let data: Data
                switch outcome {
                case .fail: throw URLError(.notConnectedToInternet)
                case .ok: data = Data(#"{"ok":true}"#.utf8)
                case .items(let items): data = try JSONEncoder().encode(["items": items])
                }
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (data, response)
            }
        }
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bench-offline-queue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func prompt(_ text: String, project: UUID = UUID(), name: String = "Bench", minutesAgo: Double) -> QueuedPrompt {
        QueuedPrompt(projectID: project, projectName: name, prompt: text,
                     queuedAt: Date(timeIntervalSinceNow: -minutesAgo * 60), device: "iPhone")
    }

    private func queue(relay: StubRelay, folder: URL, enabled: Bool = true, url: URL? = OfflineQueueTests.relay,
                       start: @escaping (QueuedPrompt) async throws -> (project: UUID, tab: UUID?)?) -> OfflineQueue {
        OfflineQueue(token: { Self.token }, isEnabled: { enabled }, relayURL: url, start: start, folder: folder,
                     transport: relay.transport)
    }

    private func pendingOnDisk(_ folder: URL) -> [QueuedPrompt] { Self.pending(in: folder) }

    private nonisolated static func pending(in folder: URL) -> [QueuedPrompt] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("pending.json")) else { return [] }
        return (try? CompanionCoding.decoder.decode([QueuedPrompt].self, from: data)) ?? []
    }

    @Test func startsTakenPromptsOldestFirst() async throws {
        let relay = StubRelay()
        let newer = prompt("Second", minutesAgo: 5), older = prompt("First", minutesAgo: 30)
        try relay.add(newer)
        try relay.add(older)
        var started: [String] = []
        var notes: [(String, String)] = []
        let queue = queue(relay: relay, folder: try folder()) { started.append($0.prompt); return (UUID(), UUID()) }
        queue.notifyPhone = { title, body, _, _ in notes.append((title, body)) }
        await queue.check()
        #expect(started == ["First", "Second"])
        #expect(notes.map(\.0) == ["Started from your queue", "Started from your queue"])
        #expect(notes.map(\.1) == ["Bench: First", "Bench: Second"])
        #expect(queue.failed.isEmpty)
    }

    @Test func notificationShowsTheFirst80Characters() async throws {
        let relay = StubRelay()
        let long = String(repeating: "a", count: 120)
        try relay.add(prompt(long, minutesAgo: 1))
        var body: String?
        let queue = queue(relay: relay, folder: try folder()) { _ in (UUID(), UUID()) }
        queue.notifyPhone = { _, text, _, _ in body = text }
        await queue.check()
        #expect(body == "Bench: " + String(repeating: "a", count: 80))
    }

    @Test func startedWithoutTabCountsAsStarted() async throws {
        let relay = StubRelay()
        let one = prompt("Hello", minutesAgo: 1)
        try relay.add(one)
        let dir = try folder()
        let agent = UUID()
        var notes: [(UUID?, UUID?)] = []
        let queue = queue(relay: relay, folder: dir) { _ in (agent, nil) }
        queue.notifyPhone = { _, _, project, tab in notes.append((project, tab)) }
        await queue.check()
        #expect(queue.failed.isEmpty)
        #expect(pendingOnDisk(dir).isEmpty)
        #expect(notes.count == 1)
        #expect(notes.first?.0 == agent)
        #expect(notes.first?.1 == nil)
    }

    @Test func gitFolderIsFoundFromAGitDirectoryFileOrAncestor() throws {
        let fm = FileManager.default
        let repo = try folder()
        try fm.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let nested = repo.appendingPathComponent("Sources/App", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        let worktree = try folder()
        try Data("gitdir: /somewhere/.git/worktrees/x\n".utf8).write(to: worktree.appendingPathComponent(".git"))
        let plain = try folder()
        #expect(OfflineQueue.isGitFolder(repo))
        #expect(OfflineQueue.isGitFolder(nested))
        #expect(OfflineQueue.isGitFolder(worktree))
        #expect(!OfflineQueue.isGitFolder(plain))
    }

    @Test func writesPendingBeforeStarting() async throws {
        let relay = StubRelay()
        let one = prompt("One", minutesAgo: 2)
        try relay.add(one)
        let dir = try folder()
        var seen: [UUID] = []
        let queue = queue(relay: relay, folder: dir) { _ in
            seen = self.pendingOnDisk(dir).map(\.id)
            return (UUID(), UUID())
        }
        await queue.check()
        #expect(seen == [one.id])
        #expect(pendingOnDisk(dir).isEmpty)
    }

    @Test func leftoverPendingIsStartedOnNextCheck() async throws {
        let dir = try folder()
        let left = prompt("Left over", minutesAgo: 10)
        try CompanionCoding.encoder.encode([left]).write(to: dir.appendingPathComponent("pending.json"))
        let relay = StubRelay()
        try relay.add(prompt("New", minutesAgo: 1))
        var started: [String] = []
        let queue = queue(relay: relay, folder: dir) { started.append($0.prompt); return (UUID(), UUID()) }
        await queue.check()
        #expect(started == ["Left over", "New"])
        #expect(pendingOnDisk(dir).isEmpty)
    }

    @Test func missingProjectGoesToFailed() async throws {
        let relay = StubRelay()
        let gone = prompt("Hello", name: "Bench", minutesAgo: 1)
        try relay.add(gone)
        let dir = try folder()
        let queue = queue(relay: relay, folder: dir) { _ in nil }
        var reported: [OfflineQueue.FailedPrompt] = []
        queue.onFailure = { reported += $0 }
        await queue.check()
        #expect(queue.failed.map(\.id) == [gone.id])
        #expect(queue.failed.first?.reason == "Bench isn't in Workbench anymore.")
        #expect(reported.map(\.id) == [gone.id])
        #expect(pendingOnDisk(dir).isEmpty)
        // Kept across launches.
        let again = self.queue(relay: StubRelay(), folder: dir) { _ in nil }
        #expect(again.failed.map(\.id) == [gone.id])
    }

    @Test func nonGitProjectGoesToFailed() async throws {
        let relay = StubRelay()
        let one = prompt("Hello", minutesAgo: 1)
        try relay.add(one)
        let queue = queue(relay: relay, folder: try folder()) { _ in throw OfflineQueue.NotGit() }
        await queue.check()
        #expect(queue.failed.map(\.id) == [one.id])
        #expect(queue.failed.first?.reason == "Queued prompts need a git project.")
    }

    @Test func unopenableItemGoesToFailed() async throws {
        let relay = StubRelay()
        let other = prompt("Secret", minutesAgo: 1)
        try relay.add(other, sealedWith: "some-other-token")
        var started = 0
        let queue = queue(relay: relay, folder: try folder()) { _ in started += 1; return (UUID(), UUID()) }
        await queue.check()
        #expect(started == 0)
        #expect(queue.failed.map(\.id) == [other.id])
        #expect(queue.failed.first?.reason == "Couldn't be unlocked. It may be from an older pairing code.")
    }

    @Test func relayFailureKeepsNothingAndRetriesLater() async throws {
        let relay = StubRelay()
        try relay.add(prompt("Later", minutesAgo: 1))
        relay.fails = true
        let dir = try folder()
        var started: [String] = []
        let queue = queue(relay: relay, folder: dir) { started.append($0.prompt); return (UUID(), UUID()) }
        await queue.check()
        #expect(started.isEmpty)
        #expect(queue.failed.isEmpty)
        #expect(pendingOnDisk(dir).isEmpty)
        relay.fails = false
        await queue.check()
        #expect(started == ["Later"])
    }

    @Test func disabledCompanionNeverCallsRelay() async throws {
        let relay = StubRelay()
        try relay.add(prompt("Hello", minutesAgo: 1))
        let queue = queue(relay: relay, folder: try folder(), enabled: false) { _ in (UUID(), UUID()) }
        await queue.check()
        #expect(relay.bodies.isEmpty)
    }

    @Test func nilURLNeverCallsRelay() async throws {
        let relay = StubRelay()
        try relay.add(prompt("Hello", minutesAgo: 1))
        let queue = queue(relay: relay, folder: try folder(), url: nil) { _ in (UUID(), UUID()) }
        await queue.check()
        #expect(relay.bodies.isEmpty)
    }

    @Test func drainTakesFromOldMailbox() async throws {
        let relay = StubRelay()
        let old = "the-old-token"
        try relay.add(prompt("From before", minutesAgo: 1), token: old)
        var started: [String] = []
        let queue = queue(relay: relay, folder: try folder()) { started.append($0.prompt); return (UUID(), UUID()) }
        await queue.drain(oldToken: old)
        #expect(relay.bodies.first?["mailbox"] as? String == QueueSeal.mailboxID(token: old))
        #expect(relay.bodies.first?["action"] as? String == "take")
        #expect(started == ["From before"])
        #expect(queue.failed.isEmpty)
    }

    @Test func retryMovesFailedIntoNewProject() async throws {
        let relay = StubRelay()
        let one = prompt("Hello", minutesAgo: 1)
        try relay.add(one)
        let replacement = UUID()
        var startedIn: [UUID] = []
        var projectExists = false
        let queue = queue(relay: relay, folder: try folder()) { prompt in
            guard projectExists else { return nil }
            startedIn.append(prompt.projectID)
            return (UUID(), UUID())
        }
        await queue.check()
        #expect(queue.failed.map(\.id) == [one.id])
        projectExists = true
        await queue.retry(one.id, in: replacement)
        #expect(startedIn == [replacement])
        #expect(queue.failed.isEmpty)
    }

    /// Holds the first start until released, so a test can check in the
    /// middle. Any later start goes straight through and is counted.
    private final class Gate {
        var starts = 0
        private var waiting: CheckedContinuation<Void, Never>?
        func pass() async {
            starts += 1
            guard starts == 1 else { return }
            await withCheckedContinuation { waiting = $0 }
        }
        func release() {
            waiting?.resume()
            waiting = nil
        }
        func untilStarted(_ count: Int) async {
            for _ in 0..<1000 where starts < count { await Task.yield() }
        }
    }

    @Test func checkDuringRetryDoesNotStartItTwice() async throws {
        let relay = StubRelay()
        let one = prompt("Hello", minutesAgo: 1)
        try relay.add(one)
        let gate = Gate()
        var slow = false
        let queue = queue(relay: relay, folder: try folder()) { _ in
            guard slow else { return nil }
            await gate.pass()
            return (UUID(), UUID())
        }
        await queue.check()
        #expect(queue.failed.map(\.id) == [one.id])
        slow = true
        let retrying = Task { await queue.retry(one.id, in: UUID()) }
        await gate.untilStarted(1)
        await queue.check()
        gate.release()
        await retrying.value
        #expect(gate.starts == 1)
        #expect(queue.failed.isEmpty)
        #expect(queue.pending.isEmpty)
    }

    @Test func checkDuringDrainDoesNotStartItTwice() async throws {
        let relay = StubRelay()
        let old = "the-old-token"
        try relay.add(prompt("From before", minutesAgo: 1), token: old)
        let gate = Gate()
        let queue = queue(relay: relay, folder: try folder()) { _ in
            await gate.pass()
            return (UUID(), UUID())
        }
        let draining = Task { await queue.drain(oldToken: old) }
        await gate.untilStarted(1)
        await queue.check()
        gate.release()
        await draining.value
        #expect(gate.starts == 1)
        #expect(queue.pending.isEmpty)
    }

    @Test func lostTakeAnswerStartsEachPromptOnceOnTheNextCheck() async throws {
        let relay = StubRelay()
        try relay.add(prompt("First", minutesAgo: 2))
        try relay.add(prompt("Second", minutesAgo: 1))
        relay.loseTakes = 1
        var started: [String] = []
        let queue = queue(relay: relay, folder: try folder()) { started.append($0.prompt); return (UUID(), UUID()) }
        await queue.check()
        #expect(started.isEmpty)
        await queue.check()
        #expect(started == ["First", "Second"])
        await queue.check()
        #expect(started == ["First", "Second"])
    }

    @Test func startedPromptHandedBackAgainIsNotStartedTwice() async throws {
        let relay = StubRelay()
        let one = prompt("Once", minutesAgo: 1)
        try relay.add(one)
        relay.failAcks = 1
        let dir = try folder()
        var started = 0
        let queue = queue(relay: relay, folder: dir) { _ in started += 1; return (UUID(), UUID()) }
        await queue.check()
        #expect(started == 1)
        // The ack failed, so the relay hands it back. A new launch still
        // knows it started.
        let again = self.queue(relay: relay, folder: dir) { _ in started += 1; return (UUID(), UUID()) }
        await again.check()
        #expect(started == 1)
        #expect(again.failed.isEmpty)
        #expect(again.pending.isEmpty)
        // The ack was tried again and went through.
        #expect(relay.actions("ack").count == 2)
        await again.check()
        #expect(relay.actions("ack").count == 2)
    }

    @Test func ackComesAfterPendingIsWritten() async throws {
        let relay = StubRelay()
        let one = prompt("Saved first", minutesAgo: 1)
        try relay.add(one)
        let dir = try folder()
        let seen = Mutex<[UUID]>([])
        let acked = Mutex<[UUID]>([])
        relay.onAck = { ids in
            acked.withLock { $0 = ids }
            seen.withLock { $0 = Self.pending(in: dir).map(\.id) }
        }
        let queue = queue(relay: relay, folder: dir) { _ in (UUID(), UUID()) }
        await queue.check()
        #expect(acked.withLock { $0 } == [one.id])
        #expect(seen.withLock { $0 } == [one.id])
    }

    @Test func failedAckForOldMailboxIsRetriedOnTheNextCheck() async throws {
        let relay = StubRelay()
        let old = "the-old-token"
        try relay.add(prompt("From before", minutesAgo: 1), token: old)
        relay.failAcks = 1
        var started = 0
        let queue = queue(relay: relay, folder: try folder()) { _ in started += 1; return (UUID(), UUID()) }
        await queue.drain(oldToken: old)
        #expect(started == 1)
        await queue.check()
        let oldMailbox = QueueSeal.mailboxID(token: old)
        let acks = relay.actions("ack").filter { $0["mailbox"] as? String == oldMailbox }
        #expect(acks.count == 2)
        #expect(started == 1)
        await queue.check()
        #expect(relay.actions("ack").filter { $0["mailbox"] as? String == oldMailbox }.count == 2)
    }

    @Test func failedIsWrittenBeforePending() async throws {
        let relay = StubRelay()
        try relay.add(prompt("Won't start", minutesAgo: 1))
        let queue = queue(relay: relay, folder: try folder()) { _ in nil }
        var writes: [String] = []
        queue.didWrite = { writes.append($0) }
        await queue.check()
        let failed = try #require(writes.lastIndex(of: "failed.json"))
        let pending = try #require(writes.lastIndex(of: "pending.json"))
        #expect(failed < pending)
        #expect(queue.failed.count == 1)
    }

    @Test func startingAPromptAlsoClearsItFromFailed() async throws {
        // Workbench stopped after saving the failure but before clearing
        // pending, so the prompt is in both.
        let dir = try folder()
        let one = prompt("Both", minutesAgo: 1)
        try CompanionCoding.encoder.encode([one]).write(to: dir.appendingPathComponent("pending.json"))
        try CompanionCoding.encoder.encode([OfflineQueue.FailedPrompt(prompt: one, reason: "Earlier")])
            .write(to: dir.appendingPathComponent("failed.json"))
        let queue = queue(relay: StubRelay(), folder: dir) { _ in (UUID(), UUID()) }
        await queue.check()
        #expect(queue.failed.isEmpty)
        #expect(queue.pending.isEmpty)
        let again = self.queue(relay: StubRelay(), folder: dir) { _ in nil }
        #expect(again.failed.isEmpty)
    }

    @Test func discardedPromptHandedBackIsNotStarted() async throws {
        let relay = StubRelay()
        let one = prompt("Thrown away", minutesAgo: 1)
        try relay.add(one)
        relay.failAcks = 1
        var starts = 0
        let queue = queue(relay: relay, folder: try folder()) { _ in starts += 1; return nil }
        await queue.check()
        queue.discard(one.id)
        await queue.check()
        #expect(starts == 1)
        #expect(queue.failed.isEmpty)
    }

    @Test func discardRemovesFailed() async throws {
        let relay = StubRelay()
        let one = prompt("Hello", minutesAgo: 1)
        try relay.add(one)
        let dir = try folder()
        let queue = queue(relay: relay, folder: dir) { _ in nil }
        await queue.check()
        #expect(queue.failed.count == 1)
        queue.discard(one.id)
        #expect(queue.failed.isEmpty)
        let again = self.queue(relay: StubRelay(), folder: dir) { _ in nil }
        #expect(again.failed.isEmpty)
    }
}
