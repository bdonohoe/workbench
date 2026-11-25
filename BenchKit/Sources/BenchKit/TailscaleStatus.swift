import Foundation

/// The parts of `tailscale status --json` Bench uses: this device's name,
/// the tailnet it's on, the devices it can see, and whether the tailnet
/// hands out HTTPS certificates.
public struct TailscaleStatus: Sendable, Equatable {
    /// This device's tailnet name, without the trailing dot.
    public var hostName: String?
    /// The tailnet's domain, like "tail1234.ts.net".
    public var tailnet: String?
    /// The names of the other devices this one can reach, without trailing
    /// dots. Includes devices shared in from other tailnets.
    public var peers: Set<String>
    /// The names Tailscale can get certificates for. Empty when HTTPS
    /// Certificates is off for the tailnet.
    public var certDomains: [String]

    public init(hostName: String? = nil, tailnet: String? = nil, peers: Set<String> = [], certDomains: [String] = []) {
        self.hostName = hostName
        self.tailnet = tailnet
        self.peers = peers
        self.certDomains = certDomains
    }

    /// Nil when the JSON doesn't describe a signed-in device.
    public init?(statusJSON: Data) {
        guard let status = (try? JSONSerialization.jsonObject(with: statusJSON)) as? [String: Any],
              let me = status["Self"] as? [String: Any],
              let name = me["DNSName"] as? String, !name.isEmpty
        else { return nil }
        hostName = Self.trimmed(name)
        let current = status["CurrentTailnet"] as? [String: Any]
        let suffix = (current?["MagicDNSSuffix"] as? String) ?? (status["MagicDNSSuffix"] as? String)
        tailnet = suffix.map(Self.trimmed).flatMap { $0.isEmpty ? nil : $0 }
        let peerList = (status["Peer"] as? [String: Any])?.values.compactMap { ($0 as? [String: Any])?["DNSName"] as? String } ?? []
        peers = Set(peerList.map(Self.trimmed).filter { !$0.isEmpty })
        certDomains = status["CertDomains"] as? [String] ?? []
    }

    /// Whether the tailnet has HTTPS Certificates turned on.
    public var hasHTTPS: Bool { !certDomains.isEmpty }

    /// Why a pairing link for `host` (a tailnet name, maybe with a path
    /// after it) won't work from this device, or nil if nothing says so.
    public func pairingProblem(host: String) -> PairingProblem? {
        let name = Self.trimmed(String(host.split(separator: "/", maxSplits: 1).first ?? Substring(host))).lowercased()
        if name == hostName?.lowercased() { return .thisDevice }
        // Peers are the best evidence: they include shared-in devices,
        // whose names are on someone else's tailnet.
        if peers.contains(where: { $0.lowercased() == name }) { return nil }
        guard let tailnet, name.hasSuffix(".ts.net") else { return nil }
        let linkTailnet = String(name.drop { $0 != "." }.dropFirst())
        if linkTailnet != tailnet.lowercased() {
            return .otherTailnet(link: linkTailnet, current: tailnet)
        }
        return .unknownDevice(String(name.prefix { $0 != "." }))
    }

    private static func trimmed(_ name: String) -> String {
        name.hasSuffix(".") ? String(name.dropLast()) : name
    }
}

/// What's wrong with a pairing link, judged from this device's tailnet.
public enum PairingProblem: Sendable, Equatable {
    /// The link is for this device itself.
    case thisDevice
    /// The link names a device on a tailnet this device isn't on.
    case otherTailnet(link: String, current: String)
    /// The tailnet matches, but no device by that name is on it.
    case unknownDevice(String)

    public var message: String {
        switch self {
        case .thisDevice:
            "That's this Mac's own pairing link. Copy the link from Workbench on the other Mac."
        case .otherTailnet(let link, let current):
            "This link is for a Mac on the tailnet \(link), but this Mac is on \(current). Turn the companion off and on again on the other Mac, then copy a fresh link. If that Mac really is on another tailnet, sign both Macs in to the same one."
        case .unknownDevice(let name):
            "Tailscale doesn't list a device named \(name) on your tailnet. It may have been renamed or signed out. Copy a fresh link from the other Mac."
        }
    }
}
