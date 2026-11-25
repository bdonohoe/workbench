import Foundation

/// What Tailscale Serve proxies on port 443, as `tailscale serve status
/// --json` reports it.
///
/// Serve files each entry under the hostname it was made for, and only uses
/// the entry when a connection asks for that exact name. Entries made before
/// a Mac or tailnet was renamed stay in the config but do nothing, and a
/// connection to the new name fails its TLS handshake. So every question here
/// is about one hostname.
public struct TailscaleServeConfig: Sendable, Equatable {
    public struct Entry: Sendable, Hashable {
        public var host: String
        public var path: String
        public var proxy: String

        public init(host: String, path: String, proxy: String) {
            self.host = host
            self.path = path
            self.proxy = proxy
        }
    }

    public var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    public init(statusJSON: Data) {
        var entries: [Entry] = []
        let status = (try? JSONSerialization.jsonObject(with: statusJSON)) as? [String: Any]
        let web = status?["Web"] as? [String: Any] ?? [:]
        for (hostPort, value) in web where hostPort.hasSuffix(":443") {
            let host = String(hostPort.dropLast(":443".count))
            let handlers = (value as? [String: Any])?["Handlers"] as? [String: Any] ?? [:]
            for (path, handler) in handlers {
                if let proxy = (handler as? [String: Any])?["Proxy"] as? String {
                    entries.append(Entry(host: host, path: path, proxy: proxy))
                }
            }
        }
        self.entries = entries
    }

    /// Where a server should be published on `host`, and whether Serve still
    /// has to be told.
    public struct Publication: Sendable, Equatable {
        /// "" for the root, or "/bench" when something else serves the root.
        public var path: String
        public var isAlreadyPublished: Bool

        public init(path: String, isAlreadyPublished: Bool) {
            self.path = path
            self.isAlreadyPublished = isAlreadyPublished
        }
    }

    public func publication(host: String, proxy: String) -> Publication {
        if let root = self.proxy(host: host, path: "/"), root != proxy {
            return Publication(path: "/bench", isAlreadyPublished: self.proxy(host: host, path: "/bench") == proxy)
        }
        return Publication(path: "", isAlreadyPublished: self.proxy(host: host, path: "/") == proxy)
    }

    /// Whether `publication` has really taken effect on `host`.
    public func serves(_ publication: Publication, host: String, proxy: String) -> Bool {
        self.proxy(host: host, path: publication.path.isEmpty ? "/" : publication.path) == proxy
    }

    /// The paths on `host` that point at `proxy`.
    public func paths(host: String, proxy: String) -> [String] {
        entries.filter { $0.host == host && $0.proxy == proxy }.map(\.path).sorted()
    }

    private func proxy(host: String, path: String) -> String? {
        entries.first { $0.host == host && $0.path == path }?.proxy
    }
}
