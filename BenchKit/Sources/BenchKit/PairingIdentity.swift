/// Which host a Mac puts in its pairing code. Phones key everything they
/// keep about a Mac on it, so it has to stay put: it follows Tailscale when
/// Tailscale has an address, sticks to the last one while Tailscale is down,
/// and falls back to a made-up local-only name otherwise.
public enum PairingIdentity {
    /// 1. The current tailnet address, if there is one. Until Serve has
    ///    said which path Bench is on (`servePathKnown`), the address is
    ///    the bare name, so a remembered one on that name keeps its path.
    /// 2. Otherwise the remembered address, if it isn't local-only and
    ///    Tailscale is still installed.
    /// 3. Otherwise `PairingInfo.localOnlyHost(mac:)`.
    public static func host(tailnetAddress: String?, remembered: String?, isTailscaleInstalled: Bool, mac: String,
                            servePathKnown: Bool = true) -> String {
        if let tailnetAddress, !tailnetAddress.isEmpty {
            if !servePathKnown, let remembered, remembered.hasPrefix(tailnetAddress + "/") { return remembered }
            return tailnetAddress
        }
        if isTailscaleInstalled, let remembered, !remembered.isEmpty,
           !PairingInfo(host: remembered, token: "").isLocalOnly {
            return remembered
        }
        return PairingInfo.localOnlyHost(mac: mac)
    }
}
