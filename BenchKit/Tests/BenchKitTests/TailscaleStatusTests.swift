import Foundation
import Testing
@testable import BenchKit

struct TailscaleStatusTests {
    /// The shape `tailscale status --json` really prints, trimmed down.
    private let json = """
    {
      "MagicDNSSuffix": "tail5b532c.ts.net",
      "CurrentTailnet": { "Name": "me@example.com", "MagicDNSSuffix": "tail5b532c.ts.net", "MagicDNSEnabled": true },
      "CertDomains": ["laptop.tail5b532c.ts.net"],
      "Self": { "DNSName": "laptop.tail5b532c.ts.net." },
      "Peer": {
        "nodekey:1": { "DNSName": "mini.tail5b532c.ts.net." },
        "nodekey:2": { "DNSName": "shared-box.tailother.ts.net." }
      }
    }
    """

    private var status: TailscaleStatus { TailscaleStatus(statusJSON: Data(json.utf8))! }

    @Test func readsStatusJSON() {
        #expect(status.hostName == "laptop.tail5b532c.ts.net")
        #expect(status.tailnet == "tail5b532c.ts.net")
        #expect(status.peers == ["mini.tail5b532c.ts.net", "shared-box.tailother.ts.net"])
        #expect(status.hasHTTPS)
    }

    @Test func noCertDomainsMeansHTTPSIsOff() {
        let off = json.replacingOccurrences(of: "\"CertDomains\": [\"laptop.tail5b532c.ts.net\"],", with: "")
        #expect(TailscaleStatus(statusJSON: Data(off.utf8))?.hasHTTPS == false)
    }

    @Test func signedOutOrBadJSONIsNil() {
        #expect(TailscaleStatus(statusJSON: Data("{}".utf8)) == nil)
        #expect(TailscaleStatus(statusJSON: Data(#"{"Self": {"DNSName": ""}}"#.utf8)) == nil)
        #expect(TailscaleStatus(statusJSON: Data("not json".utf8)) == nil)
    }

    @Test func aPeerIsFine() {
        #expect(status.pairingProblem(host: "mini.tail5b532c.ts.net") == nil)
        #expect(status.pairingProblem(host: "mini.tail5b532c.ts.net/bench") == nil)
        #expect(status.pairingProblem(host: "Mini.Tail5b532c.ts.net") == nil)
    }

    @Test func aSharedInPeerIsFine() {
        #expect(status.pairingProblem(host: "shared-box.tailother.ts.net") == nil)
    }

    @Test func anOldTailnetIsCaught() {
        #expect(status.pairingProblem(host: "mini.taila46a5d.ts.net")
            == .otherTailnet(link: "taila46a5d.ts.net", current: "tail5b532c.ts.net"))
    }

    @Test func aMissingDeviceIsCaught() {
        #expect(status.pairingProblem(host: "gone.tail5b532c.ts.net/bench") == .unknownDevice("gone"))
    }

    @Test func thisMacsOwnLinkIsCaught() {
        #expect(status.pairingProblem(host: "laptop.tail5b532c.ts.net") == .thisDevice)
    }

    /// Custom names and test addresses aren't judged.
    @Test func otherNamesAreLeftAlone() {
        #expect(status.pairingProblem(host: "ws://127.0.0.1:48803") == nil)
        #expect(status.pairingProblem(host: "mac.example.com") == nil)
    }
}
