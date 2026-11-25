import BenchKit
import Foundation

/// Talks to the Tailscale app's command line tool. Tailscale Serve is what
/// puts the companion server on the tailnet with HTTPS, so the phone can
/// reach it at the Mac's tailnet name.
nonisolated enum Tailscale {
    struct Failure: Error, LocalizedError {
        var message: String
        /// The tool was still waiting when its time ran out, along with what
        /// it had printed. It waits like this for someone to turn HTTPS on.
        var waitingOutput: String?
        /// The tailnet needs HTTPS Certificates turned on.
        var needsHTTPS = false
        var errorDescription: String? { message }
    }

    /// How long the tool gets. Everything Bench asks of it is quick, unless
    /// it's waiting on something Bench can't do.
    private static let timeout: TimeInterval = 20

    static var binary: String? {
        let app = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
        return FileManager.default.isExecutableFile(atPath: app) ? app : Tools.path("tailscale")
    }

    static var isInstalled: Bool { binary != nil }

    /// The environment to run the tool with. The Tailscale app's tool only
    /// talks to the running app when it thinks it's in a terminal. Without
    /// TERM_PROGRAM (as when Bench is opened from the Finder) it tries to
    /// start a second copy of the app, and fails.
    static var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["TERM_PROGRAM"] = environment["TERM_PROGRAM"] ?? "Bench"
        return environment
    }

    /// This Mac's name on the tailnet, without the trailing dot, or nil when
    /// Tailscale isn't running or signed in.
    static func hostName() async -> String? {
        await status()?.hostName
    }

    /// What Tailscale says about this Mac and its tailnet, or nil when it
    /// isn't running or signed in.
    static func status() async -> TailscaleStatus? {
        guard let json = try? await run(["status", "--json"]) else { return nil }
        return TailscaleStatus(statusJSON: Data(json.utf8))
    }

    /// Publishes localhost:`port` at `host` on the tailnet and returns the
    /// path it's under: "" for the root, or "/bench" when something else
    /// already serves the root. Only devices on the tailnet can reach it.
    /// Never replaces anything Bench didn't set up.
    static func serve(host: String, port: UInt16) async throws -> String {
        let mine = "http://localhost:\(port)"
        let publication = await config().publication(host: host, proxy: mine)
        guard !publication.isAlreadyPublished else { return publication.path }
        let args = publication.path.isEmpty ? ["serve", "--bg", mine] : ["serve", "--bg", "--set-path", publication.path, mine]
        let output: String
        do {
            output = try await run(args)
        } catch let failure as Failure where failure.waitingOutput != nil {
            throw httpsNeeded(toolOutput: failure.waitingOutput ?? "")
        }
        // When the tailnet hasn't turned HTTPS on, the tool can print a link
        // and exit successfully without having changed anything.
        guard await config().serves(publication, host: host, proxy: mine) else {
            throw httpsNeeded(toolOutput: output)
        }
        return publication.path
    }

    /// What to say when Serve won't start, using the tool's own link to turn
    /// HTTPS on when it gave one.
    private static func httpsNeeded(toolOutput: String) -> Failure {
        let link = toolOutput.split(whereSeparator: \.isWhitespace).first { $0.hasPrefix("https://") }
        return Failure(message: "Tailscale needs HTTPS turned on for your tailnet. Go to \(link.map(String.init) ?? httpsSettings) to turn it on, then reopen this page.",
                       needsHTTPS: true)
    }

    private static let httpsSettings = "login.tailscale.com/admin/dns"
    /// The admin console page with the HTTPS Certificates switch.
    static let httpsSettingsURL = URL(string: "https://login.tailscale.com/admin/dns")!
    static let downloadURL = URL(string: "https://tailscale.com/download")!

    /// Shown when `tailscale status` says the tailnet has no certificates.
    static let httpsOff = "HTTPS Certificates is off for your tailnet, so other devices can't connect to this Mac. Turn it on in the DNS page of the Tailscale admin console. Workbench checks again on its own."

    /// Why other devices can't connect to `address` over HTTPS, or nil if
    /// nothing says they can't. Serve gets its certificate during the first
    /// connection and fails the connection if it can't, so the only way to
    /// know is to try. Only a TLS failure counts: if this Mac can't look up
    /// its own name, say, that says nothing about other devices.
    /// Only called once `tailscale status` says HTTPS Certificates is on, so
    /// the message doesn't send people back to a switch that's already on.
    static func httpsProblem(address: String) async -> String? {
        guard let url = URL(string: "https://\(address)/") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        // Getting a first certificate can take Serve up to a minute.
        request.timeoutInterval = 75
        do {
            _ = try await probeSession.data(for: request)
            return nil
        } catch {
            guard SecureConnection.isFailure(error) else { return nil }
            return "Workbench couldn't make a secure connection to https://\(address) (\(error.localizedDescription)). HTTPS Certificates is on for your tailnet, so Tailscale may still be getting a certificate, or something on this Mac, like a VPN or security app, is in the way. Workbench checks again on its own."
        }
    }

    /// Goes straight to the tailnet. A system proxy, like a debugging proxy
    /// that swaps in its own certificate, would fail the handshake here
    /// while other devices connect fine. Nothing cached between checks.
    private static let probeSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration)
    }()

    /// Removes only the Serve paths that point at Bench's port. Entries left
    /// under a Mac's old name stay: the tool can only change the current
    /// name's, and they do nothing.
    static func stopServing(port: UInt16) async throws {
        guard let host = await hostName() else { return }
        let mine = "http://localhost:\(port)"
        for path in await config().paths(host: host, proxy: mine) {
            _ = try await run(["serve", "--https=443", "--set-path", path, "off"])
        }
    }

    /// What Serve proxies on this Mac's port 443.
    static func config() async -> TailscaleServeConfig {
        guard let json = try? await run(["serve", "status", "--json"]) else { return TailscaleServeConfig() }
        return TailscaleServeConfig(statusJSON: Data(json.utf8))
    }

    private static func run(_ args: [String]) async throws -> String {
        guard let binary else { throw Failure(message: "Tailscale isn't installed.") }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: binary)
                process.arguments = args
                process.environment = environment
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
                defer { watchdog.cancel() }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationReason == .uncaughtSignal, process.terminationStatus == SIGTERM {
                    continuation.resume(throwing: Failure(message: "tailscale \(args.first ?? "") didn't finish.",
                                                          waitingOutput: String(decoding: data, as: UTF8.self)))
                } else if process.terminationStatus == 0 {
                    continuation.resume(returning: String(decoding: data, as: UTF8.self))
                } else {
                    let message = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: Failure(message: message.isEmpty ? "tailscale \(args.first ?? "") failed" : message))
                }
            }
        }
    }
}
