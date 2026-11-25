import BenchKit
import Darwin
import Foundation
import Testing
@testable import Bench

/// Stopping the companion server lets go of everything a phone was
/// holding: its connection, its place in the device list, and the file
/// monitor behind its Files screen, whose FSEvents stream used to keep
/// running for the rest of the process.
@MainActor
struct CompanionServerTests {
    /// A port nothing is listening on right now.
    private func freePort() throws -> UInt16 {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                bind(socket, pointer, length) == 0 && getsockname(socket, pointer, &length) == 0
            }
        }
        try #require(bound)
        return UInt16(bigEndian: address.sin_port)
    }

    private func until(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(50)) }
        #expect(condition(), "\(what) didn't happen in time")
    }

    private func next(_ task: URLSessionWebSocketTask) async throws -> ServerMessage {
        let message = try await task.receive()
        let data: Data
        switch message {
        case .data(let d): data = d
        case .string(let s): data = Data(s.utf8)
        @unknown default: throw CancellationError()
        }
        return try CompanionCoding.decoder.decode(ServerMessage.self, from: data)
    }

    private func send(_ message: ClientMessage, over task: URLSessionWebSocketTask) async throws {
        try await task.send(.data(CompanionCoding.encoder.encode(message)))
    }

    @Test func stopLetsGoOfAConnectedPhoneAndItsFileMonitor() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bench-server-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: folder.appendingPathComponent("README.md"))
        let projectID = UUID()
        let state = folder.appendingPathComponent("state.json")
        try Data("""
        {"projects":[{"id":"\(projectID.uuidString)","path":"\(folder.path)","tabs":[]}],"pins":[],"groups":[]}
        """.utf8).write(to: state)

        let store = AppStore(fileURL: state)
        let project = try #require(store.project(projectID))
        let terminals = TerminalManager(store: store)
        let pullRequests = PullRequests()
        let files = FileListMonitors()
        let snapshots = CompanionSnapshots(store: store, terminals: terminals, pullRequests: pullRequests, deployments: Deployments(),
                                           monitors: RepoMonitors(), files: files, icons: ProjectIcons(),
                                           cleaner: WorktreeCleaner(store: store, terminals: terminals, pullRequests: pullRequests),
                                           shortcuts: TabShortcuts(), ports: PortScanner())
        let port = try freePort()
        let server = CompanionServer(snapshots: snapshots, token: { "pairing-code" }, port: port)
        server.start()
        try await until("the server starting") { server.isRunning }

        let task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)")!)
        task.resume()
        try await send(.hello(token: "pairing-code", device: "Test phone"), over: task)
        var welcomed = false
        for _ in 0..<5 where !welcomed {
            if case .welcome = try await next(task) { welcomed = true }
        }
        #expect(welcomed)
        try await until("the phone being listed") { server.connectedDevices == ["Test phone"] }

        try await send(.watchFiles(projectID: projectID), over: task)
        let monitor = files.monitor(for: project)
        try await until("the file monitor starting") { monitor.isWatching }

        server.stop()
        #expect(server.connectedDevices.isEmpty)
        #expect(!server.isRunning)
        #expect(!monitor.isWatching)
        // The phone's socket is closed too: nothing more arrives on it.
        await #expect(throws: (any Error).self) {
            for _ in 0..<20 { _ = try await next(task) }
        }
        task.cancel(with: .normalClosure, reason: nil)
    }
}
