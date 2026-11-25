import Foundation
import Testing
@testable import BenchKit

@Test func usesClaudesDescriptionForCommands() {
    let input: [String: Any] = ["command": "git log --oneline -30", "description": "Show recent commits"]
    #expect(ToolWording.describe(tool: "Bash", input: input) == "Showing recent commits")
    #expect(ToolWording.past("Showing recent commits") == "Showed recent commits")
}

@Test func leavesUnknownDescriptionVerbsAlone() {
    let input: [String: Any] = ["command": "x", "description": "tidy up the build folder"]
    #expect(ToolWording.describe(tool: "Bash", input: input) == "Tidy up the build folder")
    #expect(ToolWording.past("Tidy up the build folder") == "Tidy up the build folder")
}

@Test func literalKeepsTheCommand() {
    let input: [String: Any] = ["command": "git push origin main", "description": "Push the branch"]
    #expect(ToolWording.literal(tool: "Bash", input: input) == "Running git push origin main")
}

@Test func readsCommonCommandsWithoutADescription() {
    func plain(_ command: String) -> String { ToolWording.describe(tool: "Bash", input: ["command": command]) }
    #expect(plain("sed -n 1,80p Bench/Views/SidebarView.swift") == "Reading SidebarView.swift")
    #expect(plain("cd /Users/matt/Apps/Bench && cat Bench/Theme.swift") == "Reading Theme.swift")
    #expect(plain("tail -n 20 build.log") == "Reading build.log")
    #expect(plain(#"grep -n "struct \|onHover" Bench/Views/SidebarView.swift | head -40"#) == "Searching for “struct \\|onHover”")
    #expect(plain("grep -A 5 trail Bench") == "Searching for “trail”")
    #expect(plain("ls -la Bench/Views") == "Listing Views")
    #expect(plain("git status") == "Checking git status")
    #expect(plain("make test") == "Running make test")
    #expect(ToolWording.past("Reading Theme.swift") == "Read Theme.swift")
}

@Test func splitsShellOperators() {
    #expect(ShellWording.tokens("a && b | c; d") == ["a", "&&", "b", "|", "c", ";", "d"])
    #expect(ShellWording.tokens(#"echo "x | y" 'z'"#) == ["echo", "x | y", "z"])
}
