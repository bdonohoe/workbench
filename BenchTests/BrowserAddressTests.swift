import Foundation
import Testing
@testable import Bench

/// What you type in a browser tab's address field, and where it takes you.
struct BrowserAddressTests {
    private func go(_ typed: String) -> String? { BrowserAddress.url(from: typed)?.absoluteString }

    @Test func aBarePortIsADevServerOnThisMac() {
        #expect(go("5173") == "http://localhost:5173")
        #expect(go(" 3000 ") == "http://localhost:3000")
    }

    @Test func localAddressesUsePlainHTTP() {
        #expect(go("localhost:8080/admin") == "http://localhost:8080/admin")
        #expect(go("127.0.0.1:4000") == "http://127.0.0.1:4000")
        #expect(go("studio.local") == "http://studio.local")
        #expect(go("myserver:3000") == "http://myserver:3000")
    }

    @Test func sitesUseHTTPS() {
        #expect(go("apple.com") == "https://apple.com")
        #expect(go("example.com/a?b=c") == "https://example.com/a?b=c")
        #expect(go("example.com:8443") == "https://example.com:8443")
    }

    @Test func aFullAddressIsLeftAlone() {
        #expect(go("http://example.com") == "http://example.com")
        #expect(go("https://claude.ai/artifact/abc") == "https://claude.ai/artifact/abc")
        #expect(go("about:blank") == "about:blank")
    }

    @Test func anythingElseIsASearch() {
        #expect(go("swift concurrency") == BrowserAddress.searchPrefix + "swift%20concurrency")
        #expect(go("webkit") == BrowserAddress.searchPrefix + "webkit")
        #expect(go("what is 3.5 + 2") == BrowserAddress.searchPrefix + "what%20is%203.5%20%2B%202")
        #expect(go("hello.") == BrowserAddress.searchPrefix + "hello.")
        #expect(go("c++ & rust?") == BrowserAddress.searchPrefix + "c%2B%2B%20%26%20rust%3F")
    }

    @Test func nothingTypedGoesNowhere() {
        #expect(go("") == nil)
        #expect(go("   ") == nil)
    }

    @Test func theShortFormIsTheSite() {
        #expect(BrowserAddress.display(URL(string: "https://www.apple.com/mac/")!) == "apple.com")
        #expect(BrowserAddress.display(URL(string: "https://docs.swift.org/a/b")!) == "docs.swift.org")
        #expect(BrowserAddress.display(URL(string: "https://example.com:8443/x")!) == "example.com:8443")
    }

    @Test func aLocalServersShortFormKeepsItsPortAndPath() {
        #expect(BrowserAddress.display(URL(string: "http://localhost:5173/")!) == "localhost:5173")
        #expect(BrowserAddress.display(URL(string: "http://localhost:5173/settings/team")!) == "localhost:5173/settings/team")
    }

    @Test func aFileIsShownByItsName() {
        #expect(BrowserAddress.display(URL(fileURLWithPath: "/Users/me/site/docs/index.html")) == "index.html")
    }

    @Test func localMeansThisMacOrTheNetworkAroundIt() {
        #expect(BrowserAddress.isLocal(host: "localhost"))
        #expect(BrowserAddress.isLocal(host: "192.168.1.20"))
        #expect(BrowserAddress.isLocal(host: "[::1]"))
        #expect(BrowserAddress.isLocal(host: "studio.local"))
        #expect(!BrowserAddress.isLocal(host: "example.com"))
    }
}
