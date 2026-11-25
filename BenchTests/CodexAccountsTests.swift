import Foundation
import Testing
@testable import Bench

/// Codex accounts: what an account's `auth.json` says, how accounts made
/// outside Workbench are found, and what a new one shares with the main one.
struct CodexAccountsTests {
    /// A JWT with these claims. Only the middle part is read.
    private func token(_ claims: [String: Any]) -> String {
        let json = try! JSONSerialization.data(withJSONObject: claims)
        let body = json.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "e30.\(body).sig"
    }

    private func auth(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func temporaryFolder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("codex-accounts-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aChatGPTSignInNamesTheEmailAndPlan() {
        let idToken = token(["email": "you@example.com",
                             "https://api.openai.com/auth": ["chatgpt_plan_type": "plus"]])
        let status = CodexAccounts.status(fromAuth: auth(["auth_mode": "chatgpt", "tokens": ["id_token": idToken]]))
        #expect(status?.loggedIn == true)
        #expect(status?.email == "you@example.com")
        #expect(status?.summary == "Plus plan")
        #expect(status?.billing == .plan)
    }

    @Test func anAPIKeyIsPerToken() {
        let status = CodexAccounts.status(fromAuth: auth(["OPENAI_API_KEY": "sk-test", "tokens": NSNull()]))
        #expect(status?.loggedIn == true)
        #expect(status?.summary == "API key")
    }

    @Test func anEmptyAuthFileIsSignedOut() {
        let status = CodexAccounts.status(fromAuth: auth(["OPENAI_API_KEY": NSNull()]))
        #expect(status?.loggedIn == false)
        #expect(CodexAccounts.status(fromAuth: Data("not json".utf8)) == nil)
    }

    @Test func foldersGetReadableNames() {
        #expect(CodexAccounts.name(forFolder: "/Users/me/.codex-work") == "Work")
        #expect(CodexAccounts.name(forFolder: "/Users/me/.codex_side_project/") == "Side Project")
        #expect(CodexAccounts.name(forFolder: "/Users/me/.codex2") == "Account 2")
        #expect(CodexAccounts.name(forFolder: "/Users/me/.config/codex") == "Account 2")
    }

    @Test func shellProfilesNameTheirFolders() {
        let texts = [
            "export CODEX_HOME=~/.codex-work\n# export CODEX_HOME=~/.codex-old",
            "alias cw='CODEX_HOME=\"$HOME/.codex-client\" codex'",
            "set -x CODEX_HOME /opt/codex-team",
        ]
        #expect(CodexAccounts.profileSettings(texts: texts) == ["~/.codex-work", "$HOME/.codex-client", "/opt/codex-team"])
    }

    @Test func onlyFoldersThatLookLikeCodexAreFound() throws {
        let home = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: home) }
        let fm = FileManager.default
        try fm.createDirectory(at: home.appendingPathComponent(".codex-work/sessions"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent(".codex-empty"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent("elsewhere"), withIntermediateDirectories: true)
        try Data().write(to: home.appendingPathComponent("elsewhere/config.toml"))
        let found = CodexAccounts.candidateFolders(home: home.path, profileText: ["export CODEX_HOME=~/elsewhere"])
        let names = found.map { ($0 as NSString).lastPathComponent }
        #expect(names.sorted() == [".codex-work", "elsewhere"])
    }

    @Test func aNewAccountSharesSettingsButNotItsSignIn() throws {
        let root = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let main = root.appendingPathComponent("main")
        let fm = FileManager.default
        try fm.createDirectory(at: main.appendingPathComponent("skills"), withIntermediateDirectories: true)
        try Data("model = \"gpt\"".utf8).write(to: main.appendingPathComponent("config.toml"))
        try Data("{}".utf8).write(to: main.appendingPathComponent("auth.json"))
        let folder = root.appendingPathComponent("work").path
        try CodexAccounts.makeFolder(folder, sharing: true, main: main)
        let made = try fm.contentsOfDirectory(atPath: folder).sorted()
        #expect(made == ["config.toml", "skills"])
        #expect(try fm.destinationOfSymbolicLink(atPath: folder + "/config.toml") == main.appendingPathComponent("config.toml").path)
    }

    @Test func aNonMainAccountSetsCodexHome() {
        let profile = CodexProfile(id: UUID(), name: "Work", folder: "/Users/me/.codex work")
        #expect(profile.shellPrefix == "CODEX_HOME='/Users/me/.codex work' ")
        #expect(CodexProfile.main().shellPrefix == "")
        #expect(profile.sessionsFolder.path == "/Users/me/.codex work/sessions")
    }
}
