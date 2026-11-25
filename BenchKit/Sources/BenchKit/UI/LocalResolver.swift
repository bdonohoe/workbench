import Foundation
import Network

/// Finds a Mac on the home network by its Bonjour id and turns that into
/// a socket address.
public enum LocalResolver {
    public enum Failure: Error, Equatable, Sendable {
        /// This device isn't allowed to look on the local network.
        case denied
        /// Nothing answered in time: the Mac isn't on this network, or the
        /// network keeps devices apart.
        case notFound
    }

    public static let serviceType = "_workbench._tcp"

    /// Browses for the Mac's service, connects once to learn its address
    /// and port, and returns `wss://<address>:<port>/ws`.
    public static func resolve(mac: String, timeout: TimeInterval) async throws -> URL {
        let lookup = Lookup(mac: mac)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lookup.start(timeout: timeout, continuation: continuation)
            }
        } onCancel: {
            lookup.cancel()
        }
    }

    /// The socket address for a resolved endpoint. An IPv6 address goes
    /// in brackets, with its interface as `%25en0` so the URL stays valid.
    public static func socketURL(host: NWEndpoint.Host, port: NWEndpoint.Port) -> URL? {
        let text: String
        switch host {
        case .ipv4(let address):
            text = dotted(address)
        case .ipv6(let address):
            if let v4 = address.asIPv4 {
                text = dotted(v4)
            } else {
                var bytes = [UInt8](address.rawValue)
                var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                guard inet_ntop(AF_INET6, &bytes, &buffer, socklen_t(buffer.count)) != nil else { return nil }
                let plain = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                let zone = address.interface.map { "%25\($0.name)" } ?? ""
                text = "[\(plain)\(zone)]"
            }
        case .name(let name, _):
            text = name.hasSuffix(".") ? String(name.dropLast()) : name
        @unknown default:
            return nil
        }
        return URL(string: "wss://\(text):\(port.rawValue)/ws")
    }

    private static func dotted(_ address: IPv4Address) -> String {
        address.rawValue.map(String.init).joined(separator: ".")
    }

    /// True for the error the browser reports when local network access
    /// is off for this app (kDNSServiceErr_PolicyDenied).
    static func isDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error, code == -65570 { return true }
        return false
    }

    enum Reaction: Equatable { case carryOn, noteDenied, denied }

    /// What to do with a browser or connection error. Waiting on a denial
    /// is also how the first permission prompt looks while it's up, so
    /// that only counts if it's still that way at the timeout. A failure
    /// on it is final.
    static func reaction(to error: NWError, failed: Bool) -> Reaction {
        guard isDenied(error) else { return .carryOn }
        return failed ? .denied : .noteDenied
    }

    /// Why the lookup ran out of time.
    static func timeoutFailure(sawDenied: Bool) -> Failure {
        sawDenied ? .denied : .notFound
    }
}

/// One lookup. Everything here happens on `queue`.
private final class Lookup: @unchecked Sendable {
    private let mac: String
    private let queue = DispatchQueue(label: "LocalResolver")
    private var continuation: CheckedContinuation<URL, Error>?
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var finished = false
    /// Last heard, the browser or connection was waiting on a denial.
    private var sawDenied = false

    init(mac: String) { self.mac = mac }

    func start(timeout: TimeInterval, continuation: CheckedContinuation<URL, Error>) {
        queue.async { [self] in
            guard !finished else {
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            let browser = NWBrowser(for: .bonjour(type: LocalResolver.serviceType, domain: nil), using: .tcp)
            browser.stateUpdateHandler = { [self] state in
                switch state {
                case .waiting(let error): react(to: error, failed: false)
                case .failed(let error): react(to: error, failed: true)
                case .ready: sawDenied = false
                default: break
                }
            }
            browser.browseResultsChangedHandler = { [self] results, _ in found(results) }
            self.browser = browser
            browser.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [self] in
                finish(.failure(LocalResolver.timeoutFailure(sawDenied: sawDenied)))
            }
        }
    }

    func cancel() {
        queue.async { [self] in finish(.failure(CancellationError())) }
    }

    private func found(_ results: Set<NWBrowser.Result>) {
        guard !finished, connection == nil,
              let match = results.first(where: {
                  if case .service(let name, _, _, _) = $0.endpoint { return name == mac }
                  return false
              })
        else { return }
        connect(to: match.endpoint, ipv4Only: true)
    }

    /// Connects to the service just long enough to learn where it is. IPv4
    /// first, since its addresses are simplest; then any address if IPv4
    /// doesn't get there within a second.
    private func connect(to endpoint: NWEndpoint, ipv4Only: Bool) {
        let parameters = NWParameters.tcp
        if ipv4Only, let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [self] state in
            guard !finished, self.connection === connection else { return }
            switch state {
            case .ready:
                if case .hostPort(let host, let port)? = connection.currentPath?.remoteEndpoint,
                   let url = LocalResolver.socketURL(host: host, port: port) {
                    finish(.success(url))
                } else if ipv4Only {
                    fallBack(from: connection, to: endpoint)
                }
            case .waiting(let error), .failed(let error):
                let failed = if case .failed = state { true } else { false }
                if LocalResolver.isDenied(error) {
                    react(to: error, failed: failed)
                } else if ipv4Only {
                    fallBack(from: connection, to: endpoint)
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
        if ipv4Only {
            queue.asyncAfter(deadline: .now() + 1) { [self] in
                guard !finished, self.connection === connection else { return }
                fallBack(from: connection, to: endpoint)
            }
        }
    }

    private func react(to error: NWError, failed: Bool) {
        switch LocalResolver.reaction(to: error, failed: failed) {
        case .carryOn: break
        case .noteDenied: sawDenied = true
        case .denied: finish(.failure(LocalResolver.Failure.denied))
        }
    }

    private func fallBack(from connection: NWConnection, to endpoint: NWEndpoint) {
        connection.cancel()
        connect(to: endpoint, ipv4Only: false)
    }

    private func finish(_ result: Result<URL, Error>) {
        guard !finished else { return }
        finished = true
        browser?.cancel()
        connection?.cancel()
        browser = nil
        connection = nil
        continuation?.resume(with: result)
        continuation = nil
    }
}
