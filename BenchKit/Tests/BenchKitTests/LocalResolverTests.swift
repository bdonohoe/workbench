import Foundation
import Network
import Testing
@testable import BenchKit

/// Turning a Bonjour result into a socket address, and the words for
/// when the home network doesn't work out.
@MainActor
@Suite struct LocalResolverTests {
    @Test func ipv4URL() throws {
        let url = try #require(LocalResolver.socketURL(host: .ipv4(IPv4Address("192.168.1.5")!), port: 50123))
        #expect(url.absoluteString == "wss://192.168.1.5:50123/ws")
    }

    @Test func ipv6LinkLocalURL() throws {
        let address = try #require(IPv6Address("fe80::1%en0"))
        let url = try #require(LocalResolver.socketURL(host: .ipv6(address), port: 50123))
        #expect(url.absoluteString == "wss://[fe80::1%25en0]:50123/ws")
        #expect(URL(string: url.absoluteString) != nil)
        #expect(url.host(percentEncoded: false) == "fe80::1%en0")
        #expect(url.port == 50123)
    }

    @Test func hostNameURL() throws {
        let url = try #require(LocalResolver.socketURL(host: .name("studio.local", nil), port: 50123))
        #expect(url.absoluteString == "wss://studio.local:50123/ws")
    }

    @Test func deniedMapsToPlainMessage() {
        let text = CompanionClient.plain(LocalResolver.Failure.denied)
        #expect(text.contains("Local Network"))
        #expect(text.contains("Settings"))
    }

    @Test func notFoundForLocalOnlyMac() {
        #expect(CompanionClient.plain(LocalResolver.Failure.notFound)
            == "Your Mac isn't on this network. It's asleep, or you're away from home.")
    }

    private let policyDenied = NWError.dns(DNSServiceErrorType(-65570))

    @Test func waitingOnDenialKeepsWaiting() {
        // The first permission prompt looks like this while it's up.
        #expect(LocalResolver.reaction(to: policyDenied, failed: false) == .noteDenied)
    }

    @Test func failingOnDenialIsFinal() {
        #expect(LocalResolver.reaction(to: policyDenied, failed: true) == .denied)
    }

    @Test func otherErrorsCarryOn() {
        #expect(LocalResolver.reaction(to: .posix(.ECONNREFUSED), failed: true) == .carryOn)
        #expect(LocalResolver.reaction(to: .dns(DNSServiceErrorType(-65537)), failed: false) == .carryOn)
    }

    @Test func timeoutWhileDeniedIsDenied() {
        #expect(LocalResolver.timeoutFailure(sawDenied: true) == .denied)
        #expect(LocalResolver.timeoutFailure(sawDenied: false) == .notFound)
    }
}
