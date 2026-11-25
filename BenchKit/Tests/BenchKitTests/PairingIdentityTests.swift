import Testing
@testable import BenchKit

@Suite struct PairingIdentityTests {
    let mac = "0123456789abcdef0123456789abcdef"

    @Test func prefersCurrentTailnet() {
        #expect(PairingIdentity.host(tailnetAddress: "new.ts.net", remembered: "old.ts.net",
                                     isTailscaleInstalled: true, mac: mac) == "new.ts.net")
    }

    @Test func keepsRememberedWhenTailscaleIsDown() {
        #expect(PairingIdentity.host(tailnetAddress: nil, remembered: "old.ts.net/bench",
                                     isTailscaleInstalled: true, mac: mac) == "old.ts.net/bench")
    }

    @Test func dropsRememberedWhenUninstalled() {
        #expect(PairingIdentity.host(tailnetAddress: nil, remembered: "old.ts.net",
                                     isTailscaleInstalled: false, mac: mac) == PairingInfo.localOnlyHost(mac: mac))
    }

    @Test func neverRemembersLocalOnly() {
        let localOnly = PairingInfo.localOnlyHost(mac: mac)
        #expect(PairingIdentity.host(tailnetAddress: "new.ts.net", remembered: localOnly,
                                     isTailscaleInstalled: true, mac: mac) == "new.ts.net")
        // Nor keeps one made for another id.
        #expect(PairingIdentity.host(tailnetAddress: nil, remembered: PairingInfo.localOnlyHost(mac: "other"),
                                     isTailscaleInstalled: true, mac: mac) == localOnly)
    }

    @Test func localOnlyWithoutTailscale() {
        #expect(PairingIdentity.host(tailnetAddress: nil, remembered: nil,
                                     isTailscaleInstalled: false, mac: mac) == PairingInfo.localOnlyHost(mac: mac))
        #expect(PairingIdentity.host(tailnetAddress: nil, remembered: "",
                                     isTailscaleInstalled: true, mac: mac) == PairingInfo.localOnlyHost(mac: mac))
    }

    /// At launch the tailnet name is known before Serve says which path
    /// Bench is on. Until it does, a remembered address on that name keeps
    /// its path.
    @Test func keepsTheRememberedPathUntilServeAnswers() {
        #expect(PairingIdentity.host(tailnetAddress: "mac.ts.net", remembered: "mac.ts.net/bench",
                                     isTailscaleInstalled: true, mac: mac, servePathKnown: false) == "mac.ts.net/bench")
        // Once it has, the address is what it says.
        #expect(PairingIdentity.host(tailnetAddress: "mac.ts.net", remembered: "mac.ts.net/bench",
                                     isTailscaleInstalled: true, mac: mac, servePathKnown: true) == "mac.ts.net")
        // Another name is a different tailnet address, path or not.
        #expect(PairingIdentity.host(tailnetAddress: "new.ts.net", remembered: "mac.ts.net/bench",
                                     isTailscaleInstalled: true, mac: mac, servePathKnown: false) == "new.ts.net")
        #expect(PairingIdentity.host(tailnetAddress: "mac.ts.net", remembered: "mac.ts.net.other/bench",
                                     isTailscaleInstalled: true, mac: mac, servePathKnown: false) == "mac.ts.net")
    }
}
