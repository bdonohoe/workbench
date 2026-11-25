import Foundation
import Testing
@testable import BenchKit

@Suite struct QueueRelayClientTests {
    final class Recorder: @unchecked Sendable {
        var requests: [URLRequest] = []
    }

    let url = URL(string: "https://relay.example/api/queue")!
    let mailbox = String(repeating: "a", count: 64)

    func relay(status: Int = 200, body: String = "{}", recorder: Recorder = Recorder()) -> QueueRelay {
        let url = self.url
        return QueueRelay(url: url, mailbox: mailbox, transport: { request in
            recorder.requests.append(request)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        })
    }

    func expect(_ error: QueueRelayError, _ call: () async throws -> Void) async {
        do {
            try await call()
            Issue.record("Expected \(error)")
        } catch let thrown as QueueRelayError {
            #expect(thrown == error)
        } catch {
            Issue.record("Wrong error \(error)")
        }
    }

    @Test func addSendsMailboxInBodyNotURL() async throws {
        let recorder = Recorder()
        let id = UUID()
        try await relay(recorder: recorder).add(id: id, sealed: "abc")
        let request = try #require(recorder.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url == url)
        #expect(request.url?.query == nil)
        let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        #expect(body["mailbox"] as? String == mailbox)
        #expect(body["action"] as? String == "add")
        #expect(body["id"] as? String == id.uuidString)
        #expect(body["sealed"] as? String == "abc")
    }

    @Test func takeDecodesItems() async throws {
        let id = UUID()
        let body = #"{"items":[{"id":"\#(id.uuidString)","sealed":"xyz","addedAt":"2026-11-08T12:00:00.000Z"}]}"#
        let items = try await relay(body: body).take()
        #expect(items.count == 1)
        #expect(items[0].id == id)
        #expect(items[0].sealed == "xyz")
        #expect(items[0].addedAt == Date(timeIntervalSince1970: 1_794_139_200))
    }

    @Test func wholeSecondDatesDecodeToo() async throws {
        let id = UUID()
        let body = #"{"items":[{"id":"\#(id.uuidString)","sealed":"x","addedAt":"2026-11-08T12:00:00Z"}]}"#
        let items = try await relay(body: body).take()
        #expect(items[0].addedAt == Date(timeIntervalSince1970: 1_794_139_200))
    }

    @Test func listReturnsTaken() async throws {
        let waiting = UUID(), gone = UUID()
        let recorder = Recorder()
        let body = #"{"items":[{"id":"\#(waiting.uuidString)","sealed":"s","addedAt":"2026-11-08T12:00:00.500Z"}],"taken":["\#(gone.uuidString)"]}"#
        let result = try await relay(body: body, recorder: recorder).list(asking: [waiting, gone])
        #expect(result.items.map(\.id) == [waiting])
        #expect(result.taken == [gone])
        let sent = try #require(try JSONSerialization.jsonObject(with: recorder.requests[0].httpBody ?? Data()) as? [String: Any])
        #expect(sent["action"] as? String == "list")
        #expect((sent["ids"] as? [String])?.sorted() == [waiting.uuidString, gone.uuidString].sorted())
    }

    @Test func deleteSendsID() async throws {
        let recorder = Recorder()
        let id = UUID()
        try await relay(recorder: recorder).delete(id: id)
        let sent = try #require(try JSONSerialization.jsonObject(with: recorder.requests[0].httpBody ?? Data()) as? [String: Any])
        #expect(sent["action"] as? String == "delete")
        #expect(sent["id"] as? String == id.uuidString)
    }

    @Test func ackSendsIDs() async throws {
        let recorder = Recorder()
        let one = UUID(), two = UUID()
        try await relay(body: #"{"ok":true}"#, recorder: recorder).ack(ids: [one, two])
        let sent = try #require(try JSONSerialization.jsonObject(with: recorder.requests[0].httpBody ?? Data()) as? [String: Any])
        #expect(sent["action"] as? String == "ack")
        #expect(sent["mailbox"] as? String == mailbox)
        #expect(sent["ids"] as? [String] == [one.uuidString, two.uuidString])
    }

    @Test func ackFailureThrows() async {
        await expect(.badAnswer(502)) { try await relay(status: 502).ack(ids: [UUID()]) }
    }

    @Test func takeWithoutItemsIsABadAnswer() async {
        await expect(.badAnswer(200)) { _ = try await relay(body: #"{"ok":true}"#).take() }
    }

    @Test func listWithoutItemsIsABadAnswer() async {
        await expect(.badAnswer(200)) { _ = try await relay(body: #"{"taken":[]}"#).list(asking: []) }
    }

    @Test func conflictMapsToTaken() async {
        await expect(.taken) { try await relay(status: 409, body: #"{"taken":true}"#).add(id: UUID(), sealed: "x") }
    }

    @Test func tooLargeMaps() async {
        await expect(.tooLarge) { try await relay(status: 413).add(id: UUID(), sealed: "x") }
    }

    @Test func fullMaps() async {
        await expect(.full) { try await relay(status: 429).add(id: UUID(), sealed: "x") }
    }

    @Test func notConfiguredMaps() async {
        await expect(.notConfigured) { try await relay(status: 503).add(id: UUID(), sealed: "x") }
    }

    @Test func otherFailureKeepsCode() async {
        await expect(.badAnswer(500)) { try await relay(status: 500).delete(id: UUID()) }
    }

    @Test func transportThrowMapsToUnreachable() async {
        let relay = QueueRelay(url: url, mailbox: mailbox, transport: { _ in throw URLError(.notConnectedToInternet) })
        await expect(.unreachable) { try await relay.add(id: UUID(), sealed: "x") }
    }
}
