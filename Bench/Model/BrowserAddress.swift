import Foundation

/// Turns what you type in a browser tab's address field into a page to
/// load, and a page's address into the short form the field shows when
/// you're not editing it.
nonisolated enum BrowserAddress {
    /// Where plain words go.
    static let searchPrefix = "https://www.google.com/search?q="

    /// The page for what was typed: an address, a bare port on this Mac,
    /// or a search for anything that doesn't look like either.
    static func url(from typed: String) -> URL? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // A bare port like "5173" means a dev server here.
        if let port = Int(text), (1...65535).contains(port), text.allSatisfy(\.isNumber) {
            return URL(string: "http://localhost:\(port)")
        }
        if hasScheme(text) { return URL(string: text) ?? search(text) }
        guard looksLikeAddress(text) else { return search(text) }
        let scheme = isLocal(host: hostPart(of: text)) ? "http" : "https"
        guard let url = URL(string: "\(scheme)://\(text)"), url.host() != nil else { return search(text) }
        return url
    }

    /// The short form: the site, without "www." or the scheme. A local
    /// server keeps its port and path, since that's what tells them apart.
    /// A file on this Mac is its name.
    static func display(_ url: URL) -> String {
        if url.isFileURL, !url.lastPathComponent.isEmpty { return url.lastPathComponent }
        guard let host = url.host(), !host.isEmpty else { return url.absoluteString }
        var shown = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if let port = url.port { shown += ":\(port)" }
        if isLocal(host: host), url.path().count > 1 { shown += url.path() }
        return shown
    }

    /// This Mac, or a machine on the local network: served over plain
    /// http as a rule, and nothing to warn about.
    static func isLocal(host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host == "::1" { return true }
        // A dotted address, or a single-word machine name.
        let parts = host.split(separator: ".")
        if parts.count == 4, parts.allSatisfy({ Int($0).map { (0...255).contains($0) } ?? false }) { return true }
        return !host.contains(".")
    }

    private static func search(_ text: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        guard let query = text.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: searchPrefix + query)
    }

    /// "https://…", "file:///…", "about:blank". Not "localhost:3000",
    /// where what follows the colon is a port.
    private static func hasScheme(_ text: String) -> Bool {
        if text.contains("://") { return !text.contains(" ") }
        return ["about:", "data:", "mailto:"].contains { text.lowercased().hasPrefix($0) }
    }

    /// The part before any port, path or query.
    private static func hostPart(of text: String) -> String {
        let end = text.firstIndex { "/?#".contains($0) } ?? text.endIndex
        var host = String(text[..<end])
        if host.hasPrefix("["), let close = host.firstIndex(of: "]") { return String(host[...close]) }
        if let colon = host.lastIndex(of: ":") { host = String(host[..<colon]) }
        return host
    }

    /// One word with a dot or a port in it, or a local machine's name.
    private static func looksLikeAddress(_ text: String) -> Bool {
        guard !text.contains(where: \.isWhitespace) else { return false }
        let host = hostPart(of: text)
        guard !host.isEmpty else { return false }
        if host.lowercased() == "localhost" || host.hasPrefix("[") { return true }
        // "myserver:3000" and "myserver/path" are addresses; "myserver" is a search.
        if !host.contains(".") { return text.count > host.count }
        // "what is 3.5" is caught above; "e.g." and "hello." aren't sites.
        return !host.hasSuffix(".") && !host.hasPrefix(".")
    }
}
