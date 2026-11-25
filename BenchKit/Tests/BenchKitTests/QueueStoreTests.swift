import Foundation
import Testing
@testable import BenchKit

@Suite struct QueueStoreTests {
    /// A relay in memory: waiting prompts and taken ids per mailbox.
    final class FakeRelay: @unchecked Sendable {
        var waiting: [String: [UUID: String]] = [:]
        var taken: [String: Set<UUID>] = [:]
        /// How many adds to fail as unreachable before letting them through.
        var failAdds = 0
        var failDeletes = 0
        var failLists = 0
        var addedIDs: [UUID] = []
        var deletes = 0
        /// Runs while an add is on its way, before the relay stores it.
        var duringAdd: (@Sendable () async -> Void)?
        /// Runs while a list is on its way, before the relay answers.
        var duringList: (@Sendable () async -> Void)?
        /// The ids each list asked about.
        var listedIDs: [[UUID]] = []

        let url = URL(string: "https://relay.example/api/queue")!

        func client(_ mailbox: String) -> QueueRelay {
            QueueRelay(url: url, mailbox: mailbox, transport: { [self] request in
                if let duringAdd, request.httpBody.map({ String(decoding: $0, as: UTF8.self).contains("\"add\"") }) == true {
                    self.duringAdd = nil
                    await duringAdd()
                }
                if let duringList, request.httpBody.map({ String(decoding: $0, as: UTF8.self).contains("\"list\"") }) == true {
                    self.duringList = nil
                    await duringList()
                }
                return try answer(request)
            })
        }

        private func answer(_ request: URLRequest) throws -> (Data, URLResponse) {
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any] ?? [:]
            let mailbox = body["mailbox"] as? String ?? ""
            var status = 200
            var reply: [String: Any] = ["ok": true]
            switch body["action"] as? String {
            case "add":
                if failAdds > 0 {
                    failAdds -= 1
                    throw URLError(.notConnectedToInternet)
                }
                let id = UUID(uuidString: body["id"] as? String ?? "")!
                addedIDs.append(id)
                if taken[mailbox, default: []].contains(id) {
                    status = 409
                } else {
                    waiting[mailbox, default: [:]][id] = body["sealed"] as? String
                }
            case "list":
                if failLists > 0 {
                    failLists -= 1
                    throw URLError(.notConnectedToInternet)
                }
                let ids = (body["ids"] as? [String] ?? []).compactMap(UUID.init(uuidString:))
                listedIDs.append(ids)
                reply = [
                    "items": waiting[mailbox, default: [:]].map { ["id": $0.key.uuidString, "sealed": $0.value, "addedAt": "2026-11-08T12:00:00.000Z"] },
                    "taken": ids.filter { taken[mailbox, default: []].contains($0) }.map(\.uuidString),
                ]
            case "delete":
                if failDeletes > 0 {
                    failDeletes -= 1
                    throw URLError(.notConnectedToInternet)
                }
                deletes += 1
                let id = UUID(uuidString: body["id"] as? String ?? "")!
                waiting[mailbox]?[id] = nil
            default:
                status = 400
            }
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (try JSONSerialization.data(withJSONObject: reply), response)
        }

        /// What the Mac does when it wakes.
        func take(_ mailbox: String) {
            for id in waiting[mailbox, default: [:]].keys { taken[mailbox, default: []].insert(id) }
            waiting[mailbox] = [:]
        }

        /// What the relay does after 14 days.
        func forget(_ mailbox: String) {
            waiting[mailbox] = [:]
            taken[mailbox] = []
        }
    }

    let token = "token-one"
    let newToken = "token-two"
    var mailbox: String { QueueSeal.mailboxID(token: token) }
    var newMailbox: String { QueueSeal.mailboxID(token: newToken) }
    let projectID = UUID()

    func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("QueueStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    func store(_ relay: FakeRelay, folder: URL? = nil) -> QueueStoreCore {
        QueueStoreCore(folder: folder ?? self.folder(), host: "mac.example.ts.net", relay: { relay.client($0) })
    }

    func prompt(_ text: String = "Fix the footer", project: UUID? = nil) -> QueuedPrompt {
        // Whole seconds, since dates go to disk and the relay without the rest.
        QueuedPrompt(projectID: project ?? projectID, projectName: "Bench", prompt: text,
                     queuedAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)), device: "Matt's iPhone")
    }

    @Test func queueSavesThenSends() async throws {
        let relay = FakeRelay()
        let dir = folder()
        let store = store(relay, folder: dir)
        let queued = prompt()
        let error = await store.queue(queued, token: token)
        #expect(error == nil)
        let items = await store.items(projectID: nil)
        #expect(items.map(\.id) == [queued.id])
        #expect(items.first?.status == .waiting)
        #expect(items.first?.mailbox == mailbox)
        // Sealed for the Mac, which can open it.
        let sealed = try #require(relay.waiting[mailbox]?[queued.id])
        #expect(QueueSeal.open(sealed, key: QueueSeal.key(token: token), mailbox: mailbox) == queued)
        // On disk, so a new launch still has it.
        let reloaded = await self.store(relay, folder: dir).items(projectID: nil)
        #expect(reloaded == items)
    }

    @Test func failedAddStaysUnsentAndRetriesWithSameID() async {
        let relay = FakeRelay()
        relay.failAdds = 1
        let store = store(relay)
        let queued = prompt()
        let error = await store.queue(queued, token: token)
        #expect(error == .unreachable)
        #expect(await store.items(projectID: nil).first?.status == .unsent)

        await store.refresh(token: token)
        #expect(relay.addedIDs == [queued.id])
        #expect(relay.waiting[mailbox]?[queued.id] != nil)
        #expect(await store.items(projectID: nil).first?.status == .waiting)
    }

    @Test func refreshDropsStarted() async {
        let relay = FakeRelay()
        let store = store(relay)
        _ = await store.queue(prompt(), token: token)
        relay.take(mailbox)
        await store.refresh(token: token)
        #expect(await store.items(projectID: nil).isEmpty)
    }

    @Test func refreshMarksExpired() async {
        let relay = FakeRelay()
        let store = store(relay)
        _ = await store.queue(prompt(), token: token)
        relay.forget(mailbox)
        await store.refresh(token: token)
        #expect(await store.items(projectID: nil).map(\.status) == [.expired])
    }

    @Test func refreshKeepsWaiting() async {
        let relay = FakeRelay()
        let store = store(relay)
        _ = await store.queue(prompt(), token: token)
        await store.refresh(token: token)
        #expect(await store.items(projectID: nil).map(\.status) == [.waiting])
    }

    @Test func editSendsTheNewTextUnderTheSameID() async throws {
        let relay = FakeRelay()
        let store = store(relay)
        let queued = prompt()
        _ = await store.queue(queued, token: token)
        let error = await store.edit(queued.id, text: "Fix the header", token: token)
        #expect(error == nil)
        let sealed = try #require(relay.waiting[mailbox]?[queued.id])
        #expect(QueueSeal.open(sealed, key: QueueSeal.key(token: token), mailbox: mailbox)?.prompt == "Fix the header")
        #expect(await store.items(projectID: nil).first?.prompt.prompt == "Fix the header")
    }

    @Test func editOfTakenReturnsTakenAndDrops() async {
        let relay = FakeRelay()
        let store = store(relay)
        let queued = prompt()
        _ = await store.queue(queued, token: token)
        relay.take(mailbox)
        let error = await store.edit(queued.id, text: "Something else", token: token)
        #expect(error == .taken)
        #expect(await store.items(projectID: nil).isEmpty)
    }

    @Test func deleteRemovesFromRelayAndLocally() async {
        let relay = FakeRelay()
        let store = store(relay)
        let queued = prompt()
        _ = await store.queue(queued, token: token)
        await store.delete(queued.id, token: token)
        #expect(relay.waiting[mailbox]?[queued.id] == nil)
        #expect(await store.items(projectID: nil).isEmpty)
    }

    @Test func queueAgainSendsAnExpiredOne() async {
        let relay = FakeRelay()
        let store = store(relay)
        let queued = prompt()
        _ = await store.queue(queued, token: token)
        relay.forget(mailbox)
        await store.refresh(token: token)
        let error = await store.queueAgain(queued.id, token: token)
        #expect(error == nil)
        #expect(relay.waiting[mailbox]?[queued.id] != nil)
        #expect(await store.items(projectID: nil).map(\.status) == [.waiting])
    }

    @Test func tooLargeIsNotKept() async {
        let relay = FakeRelay()
        let store = store(relay)
        let error = await store.queue(prompt(String(repeating: "x", count: 40_000)), token: token)
        #expect(error == .tooLarge)
        #expect(await store.items(projectID: nil).isEmpty)
        #expect(relay.addedIDs.isEmpty)
    }

    @Test func oldMailboxCopyIsRequeuedUnderNew() async throws {
        let relay = FakeRelay()
        let store = store(relay)
        let queued = prompt()
        _ = await store.queue(queued, token: token)
        // Paired again: the old mailbox is gone without the Mac taking it.
        relay.forget(mailbox)
        await store.refresh(token: newToken)
        let items = await store.items(projectID: nil)
        #expect(items.map(\.id) == [queued.id])
        #expect(items.first?.mailbox == newMailbox)
        #expect(items.first?.status == .waiting)
        let sealed = try #require(relay.waiting[newMailbox]?[queued.id])
        #expect(QueueSeal.open(sealed, key: QueueSeal.key(token: newToken), mailbox: newMailbox)?.id == queued.id)
    }

    @Test func oldMailboxCopyTakenThereIsDropped() async {
        let relay = FakeRelay()
        let store = store(relay)
        _ = await store.queue(prompt(), token: token)
        relay.take(mailbox)
        await store.refresh(token: newToken)
        #expect(await store.items(projectID: nil).isEmpty)
        #expect(relay.waiting[newMailbox, default: [:]].isEmpty)
    }

    @Test func oldMailboxCopyStillWaitingThereIsMovedToCurrent() async throws {
        let relay = FakeRelay()
        let store = store(relay)
        let queued = prompt()
        _ = await store.queue(queued, token: token)
        await store.refresh(token: newToken)
        let items = await store.items(projectID: nil)
        #expect(items.map(\.id) == [queued.id])
        #expect(items.first?.mailbox == newMailbox)
        #expect(items.first?.status == .waiting)
        #expect(relay.waiting[mailbox]?[queued.id] == nil)
        let sealed = try #require(relay.waiting[newMailbox]?[queued.id])
        #expect(QueueSeal.open(sealed, key: QueueSeal.key(token: newToken), mailbox: newMailbox)?.id == queued.id)
    }

    @Test func editThatFailsDuringRefreshStaysUnsent() async throws {
        let relay = FakeRelay()
        let store = store(relay)
        let queued = prompt()
        let token = self.token
        _ = await store.queue(queued, token: token)
        relay.duringList = {
            relay.failAdds = 1
            _ = await store.edit(queued.id, text: "New text", token: token)
        }
        await store.refresh(token: token)
        let copy = try #require(await store.items(projectID: nil).first)
        #expect(copy.status == .unsent)
        #expect(copy.prompt.prompt == "New text")
        // The next refresh sends the new text.
        await store.refresh(token: token)
        let sealed = try #require(relay.waiting[mailbox]?[queued.id])
        #expect(QueueSeal.open(sealed, key: QueueSeal.key(token: token), mailbox: mailbox)?.prompt == "New text")
    }

    @Test func editThatFailsDuringRefreshIsNotMarkedExpired() async throws {
        let relay = FakeRelay()
        let store = store(relay)
        let queued = prompt()
        let token = self.token
        _ = await store.queue(queued, token: token)
        relay.forget(mailbox)
        relay.duringList = {
            relay.failAdds = 1
            _ = await store.edit(queued.id, text: "New text", token: token)
        }
        await store.refresh(token: token)
        #expect(await store.items(projectID: nil).first?.status == .unsent)
    }

    @Test func expiredCopiesAreNotAskedAbout() async {
        let relay = FakeRelay()
        let store = store(relay)
        let gone = prompt("Gone")
        _ = await store.queue(gone, token: token)
        relay.forget(mailbox)
        await store.refresh(token: token)
        #expect(await store.items(projectID: nil).map(\.status) == [.expired])
        let waiting = prompt("Still here")
        _ = await store.queue(waiting, token: token)
        relay.listedIDs = []
        await store.refresh(token: token)
        #expect(relay.listedIDs == [[waiting.id]])
    }

    @Test func listsAskAboutAtMost100IDsEach() async {
        let relay = FakeRelay()
        let store = store(relay)
        for index in 0..<205 {
            _ = await store.queue(prompt("Prompt \(index)"), token: token)
        }
        await store.refresh(token: token)
        #expect(relay.listedIDs.map(\.count) == [100, 100, 5])
        #expect(Set(relay.listedIDs.flatMap { $0 }).count == 205)
        #expect(await store.items(projectID: nil).allSatisfy { $0.status == .waiting })
    }

    @Test func unreadableFileIsMovedAsideNotReplaced() async throws {
        let relay = FakeRelay()
        let dir = folder()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = NotificationSeal.opaque("mac.example.ts.net")
        let file = dir.appendingPathComponent(name + ".json")
        try Data("not json".utf8).write(to: file)
        let store = store(relay, folder: dir)
        #expect(await store.items(projectID: nil).isEmpty)
        _ = await store.queue(prompt(), token: token)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let aside = try #require(names.first { $0.hasPrefix(name + ".unreadable-") && $0.hasSuffix(".json") })
        #expect(try Data(contentsOf: dir.appendingPathComponent(aside)) == Data("not json".utf8))
    }

    @Test func missingFileStartsEmptyWithNothingMoved() async throws {
        let dir = folder()
        let store = store(FakeRelay(), folder: dir)
        #expect(await store.items(projectID: nil).isEmpty)
        _ = await store.queue(prompt(), token: token)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!names.contains { $0.contains("unreadable") })
    }

    @Test func queuedFolderIsKeptOutOfBackups() async throws {
        let dir = folder()
        let store = store(FakeRelay(), folder: dir)
        _ = await store.queue(prompt(), token: token)
        #expect(try dir.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test func forgetRemovesTheFileAndTheSharedStore() async throws {
        let relay = FakeRelay()
        let dir = folder()
        let host = "gone.example"
        let one = QueueStoreCore.shared(folder: dir, host: host, relay: { relay.client($0) })
        _ = await one.queue(prompt(), token: token)
        QueueStoreCore.forget(folder: dir, host: host)
        let file = dir.appendingPathComponent(NotificationSeal.opaque(host) + ".json")
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let fresh = QueueStoreCore.shared(folder: dir, host: host, relay: { relay.client($0) })
        #expect(fresh !== one)
        #expect(await fresh.items(projectID: nil).isEmpty)
    }

    @Test func offlineDeleteIsRetriedAndNeverComesBack() async {
        let relay = FakeRelay()
        let dir = folder()
        let first = store(relay, folder: dir)
        let queued = prompt()
        _ = await first.queue(queued, token: token)
        relay.failDeletes = 1
        await first.delete(queued.id, token: token)
        #expect(await first.items(projectID: nil).isEmpty)
        #expect(relay.waiting[mailbox]?[queued.id] != nil)

        // Kept on disk: a new launch still finishes the delete.
        let again = store(relay, folder: dir)
        await again.refresh(token: token)
        #expect(relay.waiting[mailbox]?[queued.id] == nil)
        #expect(await again.items(projectID: nil).isEmpty)
        let deletes = relay.deletes
        await again.refresh(token: token)
        #expect(relay.deletes == deletes)
        #expect(await again.items(projectID: nil).isEmpty)
    }

    @Test func sendFinishingAfterDeleteTakesItBack() async {
        let relay = FakeRelay()
        let store = store(relay)
        let queued = prompt()
        let token = self.token
        relay.duringAdd = { await store.delete(queued.id, token: token) }
        _ = await store.queue(queued, token: token)
        #expect(relay.addedIDs == [queued.id])
        #expect(relay.waiting[mailbox]?[queued.id] == nil)
        #expect(await store.items(projectID: nil).isEmpty)
    }

    @Test func editOfOldMailboxCopyTakenThereReturnsTaken() async {
        let relay = FakeRelay()
        let store = store(relay)
        let queued = prompt()
        _ = await store.queue(queued, token: token)
        // Paired again, and the Mac drained the old mailbox.
        relay.take(mailbox)
        let error = await store.edit(queued.id, text: "Changed", token: newToken)
        #expect(error == .taken)
        #expect(await store.items(projectID: nil).isEmpty)
        #expect(relay.addedIDs == [queued.id])
        #expect(relay.waiting[newMailbox, default: [:]].isEmpty)
    }

    @Test func editOfOldMailboxCopyWaitsWhenItCantAsk() async {
        let relay = FakeRelay()
        let store = store(relay)
        let queued = prompt()
        _ = await store.queue(queued, token: token)
        relay.failLists = 1
        let error = await store.edit(queued.id, text: "Changed", token: newToken)
        #expect(error == .unreachable)
        let items = await store.items(projectID: nil)
        #expect(items.first?.mailbox == mailbox)
        #expect(items.first?.status == .waiting)
        #expect(items.first?.prompt.prompt == queued.prompt)
        #expect(relay.waiting[newMailbox, default: [:]].isEmpty)
    }

    @Test func editMovesAnOldMailboxCopyStillWaitingThere() async {
        let relay = FakeRelay()
        let store = store(relay)
        let queued = prompt()
        _ = await store.queue(queued, token: token)
        let error = await store.edit(queued.id, text: "Changed", token: newToken)
        #expect(error == nil)
        #expect(relay.waiting[mailbox]?[queued.id] == nil)
        #expect(relay.waiting[newMailbox]?[queued.id] != nil)
        #expect(await store.items(projectID: nil).first?.mailbox == newMailbox)
    }

    @Test func movesToNewHost() async throws {
        let relay = FakeRelay()
        let dir = folder()
        let old = QueueStoreCore.shared(folder: dir, host: "a", relay: { relay.client($0) })
        let queued = prompt()
        _ = await old.queue(queued, token: token)
        QueueStoreCore.move(folder: dir, from: "a", to: "b")

        let oldFile = dir.appendingPathComponent(NotificationSeal.opaque("a") + ".json")
        #expect(!FileManager.default.fileExists(atPath: oldFile.path))
        let moved = QueueStoreCore.shared(folder: dir, host: "b", relay: { relay.client($0) })
        #expect(await moved.items(projectID: nil).map(\.id) == [queued.id])

        // The old host's store is gone from the table, and the one still
        // held doesn't write the old file again.
        let fresh = QueueStoreCore.shared(folder: dir, host: "a", relay: { relay.client($0) })
        #expect(fresh !== old)
        _ = await old.queue(prompt("Late"), token: token)
        #expect(!FileManager.default.fileExists(atPath: oldFile.path))
        #expect(await fresh.items(projectID: nil).isEmpty)
    }

    @Test func moveDropsTheNewHostsStaleStore() async throws {
        let relay = FakeRelay()
        let dir = folder()
        let stale = QueueStoreCore.shared(folder: dir, host: "b", relay: { relay.client($0) })
        let old = QueueStoreCore.shared(folder: dir, host: "a", relay: { relay.client($0) })
        let queued = prompt()
        _ = await old.queue(queued, token: token)
        QueueStoreCore.move(folder: dir, from: "a", to: "b")
        let moved = QueueStoreCore.shared(folder: dir, host: "b", relay: { relay.client($0) })
        #expect(moved !== stale)
        #expect(await moved.items(projectID: nil).map(\.id) == [queued.id])
    }

    @Test func sharedGivesOneStorePerFile() {
        let relay = FakeRelay()
        let dir = folder()
        let one = QueueStoreCore.shared(folder: dir, host: "a.example", relay: { relay.client($0) })
        let same = QueueStoreCore.shared(folder: dir, host: "a.example", relay: { relay.client($0) })
        let other = QueueStoreCore.shared(folder: dir, host: "b.example", relay: { relay.client($0) })
        #expect(one === same)
        #expect(one !== other)
    }

    @Test func itemsFilterByProject() async {
        let relay = FakeRelay()
        let store = store(relay)
        let other = UUID()
        let mine = prompt("One")
        _ = await store.queue(mine, token: token)
        _ = await store.queue(prompt("Two", project: other), token: token)
        #expect(await store.items(projectID: projectID).map(\.id) == [mine.id])
        #expect(await store.items(projectID: nil).count == 2)
    }
}
