import BenchKit
import Darwin
import Foundation
import Network
import Security
import Testing
@testable import Bench

/// The home network listener: TLS with the Mac's own certificate, which a
/// phone pins, feeding the same hello and token check as the localhost one.
@MainActor
@Suite(.serialized)
struct LocalListenerTests {
    /// Answers the server-trust challenge by the pin alone, as the phone does.
    private final class PinDelegate: NSObject, URLSessionDelegate {
        let pin: String
        init(pin: String) { self.pin = pin }

        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
            -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust,
                  CertificatePin.matches(trust, pin: pin) else { return (.cancelAuthenticationChallenge, nil) }
            return (.useCredential, URLCredential(trust: trust))
        }
    }

    /// The pairing code, which a test can change as "Make a New Code" does.
    private final class Code {
        var value = "pairing-code"
    }

    private struct Setup {
        let server: CompanionServer
        let code: Code
        let identity: LocalIdentity
        let folder: URL
        let label: String
    }

    private func makeServer(port: UInt16? = nil, identityLater: Bool = false) throws -> Setup {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bench-local-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let state = folder.appendingPathComponent("state.json")
        try Data(#"{"projects":[],"pins":[],"groups":[]}"#.utf8).write(to: state)
        let store = AppStore(fileURL: state)
        let terminals = TerminalManager(store: store)
        let pullRequests = PullRequests()
        let snapshots = CompanionSnapshots(store: store, terminals: terminals, pullRequests: pullRequests, deployments: Deployments(),
                                           monitors: RepoMonitors(), files: FileListMonitors(), icons: ProjectIcons(),
                                           cleaner: WorktreeCleaner(store: store, terminals: terminals, pullRequests: pullRequests),
                                           shortcuts: TabShortcuts(), ports: PortScanner())
        let label = "Workbench local network test \(UUID().uuidString)"
        let identity = try LocalIdentity.loadOrMake(folder: folder, keychainLabel: label)
        let code = Code()
        let server = CompanionServer(snapshots: snapshots, token: { code.value }, port: try port ?? freePort(),
                                     identity: identityLater ? nil : identity, advertises: false)
        return Setup(server: server, code: code, identity: identity, folder: folder, label: label)
    }

    private func cleanUp(_ setup: Setup) {
        setup.server.stop()
        LocalIdentity.forget(keychainLabel: setup.label)
        try? FileManager.default.removeItem(at: setup.folder)
    }

    /// A port nothing is listening on right now, for the localhost listener.
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

    private func session(pin: String) -> URLSession {
        URLSession(configuration: .ephemeral, delegate: PinDelegate(pin: pin), delegateQueue: nil)
    }

    private func socket(_ session: URLSession, port: UInt16) -> URLSessionWebSocketTask {
        let task = session.webSocketTask(with: URL(string: "wss://127.0.0.1:\(port)/ws")!)
        task.resume()
        return task
    }

    /// Says hello and returns the welcome's features, or nil if the server
    /// closed the connection or answered with anything else first.
    private func hello(_ token: String, over task: URLSessionWebSocketTask) async -> [String]? {
        do {
            try await send(.hello(token: token, device: "Test phone"), over: task)
            for _ in 0..<5 {
                switch try await next(task) {
                case .welcome(_, _, let features, _): return features
                case .error: return nil
                default: continue
                }
            }
        } catch {}
        return nil
    }

    private func started(_ setup: Setup) async throws -> UInt16 {
        setup.server.start()
        try await until("the local listener starting") { setup.server.localPort != nil }
        return try #require(setup.server.localPort)
    }

    @Test func pinnedClientConnects() async throws {
        let setup = try makeServer()
        defer { cleanUp(setup) }
        let port = try await started(setup)
        let session = session(pin: setup.identity.fingerprint)
        defer { session.invalidateAndCancel() }
        let task = socket(session, port: port)
        let features = await hello("pairing-code", over: task)
        #expect(features?.contains(CompanionFeature.localNetwork) == true)
        try await until("the phone being listed") { setup.server.connectedDevices == ["Test phone"] }
        task.cancel(with: .normalClosure, reason: nil)
    }

    @Test func wrongPinIsRejected() async throws {
        let setup = try makeServer()
        defer { cleanUp(setup) }
        let port = try await started(setup)
        let session = session(pin: String(repeating: "0", count: 64))
        defer { session.invalidateAndCancel() }
        let task = socket(session, port: port)
        var failure: Error?
        do {
            try await send(.hello(token: "pairing-code", device: "Test phone"), over: task)
            _ = try await next(task)
        } catch {
            failure = error
        }
        let code = (failure as? URLError)?.code
        #expect([.cancelled, .serverCertificateUntrusted, .secureConnectionFailed].contains(code), "got \(String(describing: failure))")
        try await Task.sleep(for: .milliseconds(300))
        #expect(setup.server.connectedDevices.isEmpty)
    }

    @Test func badTokensGetThrottled() async throws {
        let setup = try makeServer()
        defer { cleanUp(setup) }
        let port = try await started(setup)
        let session = session(pin: setup.identity.fingerprint)
        defer { session.invalidateAndCancel() }
        for attempt in 0..<5 {
            let task = socket(session, port: port)
            try await send(.hello(token: "wrong-\(attempt)", device: "Guesser"), over: task)
            guard case .error = try await next(task) else {
                Issue.record("a bad token wasn't refused")
                return
            }
            task.cancel(with: .normalClosure, reason: nil)
        }
        let task = socket(session, port: port)
        let features = await hello("pairing-code", over: task)
        #expect(features == nil)
        #expect(setup.server.connectedDevices.isEmpty)
        task.cancel(with: .normalClosure, reason: nil)
    }

    private func refused(_ token: String, session: URLSession, port: UInt16) async throws -> Bool {
        let task = socket(session, port: port)
        defer { task.cancel(with: .normalClosure, reason: nil) }
        try await send(.hello(token: token, device: "Phone"), over: task)
        guard case .error = try await next(task) else { return false }
        return true
    }

    /// Guessed out, then "Make a New Code": the count starts over, so the
    /// phone that scans the new code gets in.
    @Test func aNewCodeClearsTheThrottle() async throws {
        let setup = try makeServer()
        defer { cleanUp(setup) }
        let port = try await started(setup)
        let session = session(pin: setup.identity.fingerprint)
        defer { session.invalidateAndCancel() }
        for attempt in 0..<5 { #expect(try await refused("wrong-\(attempt)", session: session, port: port)) }
        let blocked = socket(session, port: port)
        #expect(await hello("pairing-code", over: blocked) == nil)
        blocked.cancel(with: .normalClosure, reason: nil)

        setup.code.value = "a-new-code"
        let task = socket(session, port: port)
        #expect(await hello("a-new-code", over: task) != nil)
        task.cancel(with: .normalClosure, reason: nil)
    }

    /// A phone still using the code from before isn't guessing: it's
    /// refused, but doesn't lock out the address for the new code.
    @Test func theOldCodeDoesNotCountAsAGuess() async throws {
        let setup = try makeServer()
        defer { cleanUp(setup) }
        let port = try await started(setup)
        let session = session(pin: setup.identity.fingerprint)
        defer { session.invalidateAndCancel() }
        let first = socket(session, port: port)
        #expect(await hello("pairing-code", over: first) != nil)
        first.cancel(with: .normalClosure, reason: nil)

        setup.code.value = "a-new-code"
        for _ in 0..<6 { #expect(try await refused("pairing-code", session: session, port: port)) }
        let task = socket(session, port: port)
        #expect(await hello("a-new-code", over: task) != nil)
        task.cancel(with: .normalClosure, reason: nil)
    }

    @Test func stopClosesLocalClients() async throws {
        let setup = try makeServer()
        defer { cleanUp(setup) }
        let port = try await started(setup)
        let session = session(pin: setup.identity.fingerprint)
        defer { session.invalidateAndCancel() }
        let task = socket(session, port: port)
        #expect(await hello("pairing-code", over: task) != nil)

        setup.server.stop()
        #expect(setup.server.localPort == nil)
        await #expect(throws: (any Error).self) {
            for _ in 0..<20 { _ = try await next(task) }
        }

        let again = try await started(setup)
        let second = socket(session, port: again)
        #expect(await hello("pairing-code", over: second) != nil)
        second.cancel(with: .normalClosure, reason: nil)
    }

    /// Something else listening on 127.0.0.1:<port>, as MAMP might.
    private func occupy() throws -> (socket: Int32, port: UInt16) {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
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
        guard bound, listen(socket, 1) == 0 else {
            close(socket)
            throw CancellationError()
        }
        return (socket, UInt16(bigEndian: address.sin_port))
    }

    @Test func aTakenLocalhostPortLeavesTheHomeListenerRunning() async throws {
        let taken = try occupy()
        defer { close(taken.socket) }
        let setup = try makeServer(port: taken.port)
        defer { cleanUp(setup) }
        let port = try await started(setup)
        try await until("the localhost listener failing") { setup.server.lastError != nil }
        #expect(!setup.server.isRunning)
        // Still there after the localhost failure, and still taking phones.
        #expect(setup.server.localPort == port)
        let session = session(pin: setup.identity.fingerprint)
        defer { session.invalidateAndCancel() }
        let task = socket(session, port: port)
        #expect(await hello("pairing-code", over: task) != nil)
        task.cancel(with: .normalClosure, reason: nil)
    }

    @Test func identityIsStable() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bench-local-\(UUID().uuidString)")
        let label = "Workbench local network test \(UUID().uuidString)"
        defer {
            LocalIdentity.forget(keychainLabel: label)
            try? FileManager.default.removeItem(at: folder)
        }
        let first = try LocalIdentity.loadOrMake(folder: folder, keychainLabel: label)
        let second = try LocalIdentity.loadOrMake(folder: folder, keychainLabel: label)
        #expect(first.macID == second.macID)
        #expect(first.fingerprint == second.fingerprint)
        #expect(first.macID.count == 32 && first.macID.allSatisfy(\.isHexDigit) && first.macID == first.macID.lowercased())

        // A lost certificate means a new one, but the Mac keeps its id.
        try FileManager.default.removeItem(at: folder.appendingPathComponent("local-cert.der"))
        let third = try LocalIdentity.loadOrMake(folder: folder, keychainLabel: label)
        #expect(third.macID == first.macID)
        #expect(third.fingerprint != first.fingerprint)
    }

    /// Only a key that's really gone, or a certificate that's gone or for
    /// another key, means a new certificate. A keychain that can't be read
    /// right now (locked, a denied prompt) is an error to try again later:
    /// remaking would change the fingerprint every paired phone pins.
    @Test func onlyAMissingOrMismatchedKeyRemakesTheCertificate() {
        #expect(LocalIdentity.plan(hasCertificate: true, keyStatus: errSecSuccess, keyMatches: true) == .use)
        #expect(LocalIdentity.plan(hasCertificate: true, keyStatus: errSecSuccess, keyMatches: false) == .remake)
        #expect(LocalIdentity.plan(hasCertificate: false, keyStatus: errSecSuccess, keyMatches: false) == .remake)
        #expect(LocalIdentity.plan(hasCertificate: true, keyStatus: errSecItemNotFound, keyMatches: false) == .remake)
        #expect(LocalIdentity.plan(hasCertificate: false, keyStatus: errSecItemNotFound, keyMatches: false) == .remake)
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled, errSecNoSuchKeychain] {
            #expect(LocalIdentity.plan(hasCertificate: true, keyStatus: status, keyMatches: false) == .fail(status))
            #expect(LocalIdentity.plan(hasCertificate: false, keyStatus: status, keyMatches: false) == .fail(status))
        }
    }

    /// The identity loads off the main actor, after the server has started.
    @Test func identityArrivingLaterStartsTheLocalListener() async throws {
        let setup = try makeServer(identityLater: true)
        defer { cleanUp(setup) }
        setup.server.start()
        #expect(setup.server.localPort == nil)
        setup.server.useIdentity(setup.identity)
        try await until("the local listener starting") { setup.server.localPort != nil }
    }

    /// Given before start, it waits for start.
    @Test func identityBeforeStartWaitsForStart() async throws {
        let setup = try makeServer(identityLater: true)
        defer { cleanUp(setup) }
        setup.server.useIdentity(setup.identity)
        try await Task.sleep(for: .milliseconds(300))
        #expect(setup.server.localPort == nil)
        _ = try await started(setup)
    }

    @Test func identityFailureShowsAsLocalError() throws {
        let setup = try makeServer(identityLater: true)
        defer { cleanUp(setup) }
        setup.server.identityFailed("Couldn't make a key")
        #expect(setup.server.localError == "Couldn't make a key")
    }

    /// Only the release app uses the real keychain label and folder: dev
    /// builds are signed differently, so sharing its key would get the
    /// release app a keychain prompt, and sharing its files a remake loop.
    @Test func identityPlaces() {
        let support = URL(fileURLWithPath: "/Users/x/Library/Application Support/Bench")
        let real = Companion.identityPlace(support: support, suffix: nil, isDebug: false)
        #expect(real.label == "Workbench local network")
        #expect(real.folder == support)

        let beta = Companion.identityPlace(support: support.deletingLastPathComponent().appendingPathComponent("Bench-beta"),
                                           suffix: "beta", isDebug: false)
        #expect(beta.label == "Workbench local network (beta)")
        #expect(beta.folder.lastPathComponent == "Bench-beta")

        let debug = Companion.identityPlace(support: support, suffix: nil, isDebug: true)
        #expect(debug.label != real.label)
        #expect(debug.folder != real.folder)

        // Two debug copies with their own support folders don't share a key.
        let other = Companion.identityPlace(support: URL(fileURLWithPath: "/tmp/bench-two"), suffix: nil, isDebug: true)
        #expect(other.label != debug.label)
        #expect(other.folder != debug.folder)
    }
}
