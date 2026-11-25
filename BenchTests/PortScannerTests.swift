import Testing
@testable import Bench

/// The agents' own ports stay out of a tab's list of servers.
struct PortScannerTests {
    @Test func agentsAreRecognizedByProgramName() {
        #expect(PortScanner.isAgent(["claude", "--settings", "hooks.json"]))
        #expect(PortScanner.isAgent(["/Users/me/.local/bin/claude"]))
        #expect(PortScanner.isAgent(["/opt/homebrew/bin/codex", "resume"]))
    }

    @Test func otherServersStay() {
        #expect(!PortScanner.isAgent(["node", "/app/node_modules/.bin/vite"]))
        #expect(!PortScanner.isAgent(["bun", "run", "dev"]))
        #expect(!PortScanner.isAgent(["python3", "-m", "http.server"]))
        #expect(!PortScanner.isAgent(["claude-proxy"]))
        #expect(!PortScanner.isAgent([]))
    }
}
