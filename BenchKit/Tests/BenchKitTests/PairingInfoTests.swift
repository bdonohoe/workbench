import Foundation
import Testing
@testable import BenchKit

@Suite struct PairingInfoTests {
    @Test func roundTripsWithLocalPart() throws {
        let info = PairingInfo(host: "a.ts.net", token: "t", local: .init(mac: "m1", fingerprint: "ab"))
        #expect(PairingInfo(url: try #require(info.url)) == info)
    }

    @Test func oldCodesStillParse() throws {
        let url = try #require(URL(string: "bench://pair?host=a.ts.net&token=t"))
        let info = try #require(PairingInfo(url: url))
        #expect(info.local == nil)
    }

    @Test func ignoresHalfALocalPart() throws {
        let url = try #require(URL(string: "bench://pair?host=a.ts.net&token=t&mac=m1"))
        let info = try #require(PairingInfo(url: url))
        #expect(info.local == nil)
    }

    @Test func decodesSavedPairingsFromBeforeLocal() throws {
        let json = Data(#"{"host":"a","token":"t"}"#.utf8)
        let info = try JSONDecoder().decode(PairingInfo.self, from: json)
        #expect(info.local == nil)
    }

    @Test func localOnlyHasNoTailscaleURL() {
        let info = PairingInfo(host: PairingInfo.localOnlyHost(mac: "m1"), token: "t")
        #expect(info.socketURL == nil)
        #expect(info.isLocalOnly)
    }
}
