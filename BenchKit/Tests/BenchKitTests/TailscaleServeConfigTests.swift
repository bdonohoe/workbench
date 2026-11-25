import Foundation
import Testing
@testable import BenchKit

struct TailscaleServeConfigTests {
    private let mine = "http://localhost:48800"
    private let host = "new-name.tail1234.ts.net"
    private let oldHost = "old-name.tail1234.ts.net"

    private func entry(_ host: String, _ path: String, _ proxy: String) -> TailscaleServeConfig.Entry {
        .init(host: host, path: path, proxy: proxy)
    }

    /// The shape `tailscale serve status --json` really prints.
    @Test func readsStatusJSON() {
        let json = """
        {
          "TCP": { "443": { "HTTPS": true } },
          "Web": {
            "new-name.tail1234.ts.net:443": { "Handlers": { "/": { "Proxy": "http://localhost:48800" } } },
            "new-name.tail1234.ts.net:8443": { "Handlers": { "/": { "Proxy": "http://localhost:9000" } } }
          }
        }
        """
        let config = TailscaleServeConfig(statusJSON: Data(json.utf8))
        #expect(config.entries == [entry(host, "/", mine)])
    }

    @Test func emptyOrBadStatusMeansNoEntries() {
        #expect(TailscaleServeConfig(statusJSON: Data("{}".utf8)).entries.isEmpty)
        #expect(TailscaleServeConfig(statusJSON: Data("not json".utf8)).entries.isEmpty)
    }

    @Test func publishesAtTheRootWhenNothingIsThere() {
        let publication = TailscaleServeConfig().publication(host: host, proxy: mine)
        #expect(publication == .init(path: "", isAlreadyPublished: false))
    }

    @Test func leavesItsOwnEntryAlone() {
        let config = TailscaleServeConfig(entries: [entry(host, "/", mine)])
        #expect(config.publication(host: host, proxy: mine) == .init(path: "", isAlreadyPublished: true))
    }

    /// A renamed Mac: the entry is still there, but only for the old name, so
    /// connections to the new name would fail their TLS handshake.
    @Test func entryForAnOldNameDoesNotCountAsPublished() {
        let config = TailscaleServeConfig(entries: [entry(oldHost, "/", mine)])
        #expect(config.publication(host: host, proxy: mine) == .init(path: "", isAlreadyPublished: false))
    }

    @Test func someoneElsesRootOnAnOldNameDoesNotPushUsToBench() {
        let config = TailscaleServeConfig(entries: [entry(oldHost, "/", "http://localhost:3000")])
        #expect(config.publication(host: host, proxy: mine).path == "")
    }

    @Test func movesAsideForSomeoneElsesRoot() {
        let config = TailscaleServeConfig(entries: [entry(host, "/", "http://localhost:3000")])
        #expect(config.publication(host: host, proxy: mine) == .init(path: "/bench", isAlreadyPublished: false))

        let both = TailscaleServeConfig(entries: [entry(host, "/", "http://localhost:3000"), entry(host, "/bench", mine)])
        #expect(both.publication(host: host, proxy: mine) == .init(path: "/bench", isAlreadyPublished: true))
    }

    /// The CLI can exit 0 without changing anything, when the tailnet still
    /// has to turn HTTPS on.
    @Test func servesOnlyWhenTheEntryIsThereForThisName() {
        let root = TailscaleServeConfig.Publication(path: "", isAlreadyPublished: false)
        #expect(!TailscaleServeConfig().serves(root, host: host, proxy: mine))
        #expect(!TailscaleServeConfig(entries: [entry(oldHost, "/", mine)]).serves(root, host: host, proxy: mine))
        #expect(TailscaleServeConfig(entries: [entry(host, "/", mine)]).serves(root, host: host, proxy: mine))

        let aside = TailscaleServeConfig.Publication(path: "/bench", isAlreadyPublished: false)
        #expect(TailscaleServeConfig(entries: [entry(host, "/bench", mine)]).serves(aside, host: host, proxy: mine))
    }

    @Test func pathsToRemoveAreOnlyOursOnThisName() {
        let config = TailscaleServeConfig(entries: [
            entry(host, "/bench", mine),
            entry(host, "/", "http://localhost:3000"),
            entry(oldHost, "/", mine),
        ])
        #expect(config.paths(host: host, proxy: mine) == ["/bench"])
    }
}
