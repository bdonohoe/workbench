import Testing
@testable import Bench

/// Turning off Ghostty's ssh wrapper, which needs a `ghostty` program Bench doesn't have.
struct ShellFeaturesTests {
    // Bits: cursor 0, sudo 1, title 2, ssh-env 3, ssh-terminfo 4, path 5.

    @Test func leavesConfigAloneWithoutSSH() {
        #expect(GhosttyRuntime.shellFeaturesWithoutSSH(0b100101) == nil)
        #expect(GhosttyRuntime.shellFeaturesWithoutSSH(0) == nil)
    }

    @Test func turnsOffSSHAndKeepsTheRest() {
        // Defaults plus ssh-env and sudo.
        #expect(GhosttyRuntime.shellFeaturesWithoutSSH(0b101111)
            == "shell-integration-features = cursor,sudo,title,no-ssh-env,no-ssh-terminfo,path\n")
        // Everything on (`= true`).
        #expect(GhosttyRuntime.shellFeaturesWithoutSSH(0b111111)
            == "shell-integration-features = cursor,sudo,title,no-ssh-env,no-ssh-terminfo,path\n")
        // Only ssh-terminfo.
        #expect(GhosttyRuntime.shellFeaturesWithoutSSH(0b010000)
            == "shell-integration-features = no-cursor,no-sudo,no-title,no-ssh-env,no-ssh-terminfo,no-path\n")
    }
}
