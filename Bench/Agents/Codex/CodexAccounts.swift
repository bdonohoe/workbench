import BenchKit
import Foundation
import Observation
import Synchronization

/// One Codex sign-in that Workbench can start Codex tabs with.
///
/// Codex keeps an account's sign-in, settings, and sessions in one folder:
/// `~/.codex` normally, or whatever `CODEX_HOME` names. So a second account
/// is a second folder, the same way Claude Code's are (`ClaudeProfile`).
/// The main account leaves `CODEX_HOME` alone; every other one sets it.
nonisolated struct CodexProfile: Codable, Identifiable, Hashable, Sendable {
    /// The main account, the one Codex uses without being told.
    static let mainID = UUID(uuidString: "00000000-0000-0000-0000-00000000C0DE")!

    var id: UUID
    var name: String
    /// What `CODEX_HOME` is set to. Nil for the main account.
    var folder: String?
    /// True when Workbench made the folder, rather than finding it.
    var madeByWorkbench: Bool?

    var isMain: Bool { folder == nil }

    static func main(named name: String = "Main") -> CodexProfile {
        CodexProfile(id: mainID, name: name, folder: nil)
    }

    /// The account's folder on disk.
    var home: URL {
        if let folder { return URL(fileURLWithPath: CodexAccounts.expand(folder), isDirectory: true) }
        return Self.defaultHome
    }

    /// Where Codex keeps everything when nothing says otherwise:
    /// `$CODEX_HOME` as Workbench was started, or `~/.codex`.
    static var defaultHome: URL {
        ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    /// Where Codex keeps this account's session files.
    var sessionsFolder: URL { home.appendingPathComponent("sessions", isDirectory: true) }

    /// What to type before `codex` to use this account. Empty for the main one.
    var shellPrefix: String {
        guard let folder else { return "" }
        return "CODEX_HOME=\(shellQuote(folder)) "
    }

    /// The folder as people write it, with ~ for the home folder.
    var displayFolder: String {
        let path = folder ?? Self.defaultHome.path
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

/// The Codex accounts Workbench knows: the main one, plus any others it
/// found on this Mac or you added. Each project picks one for its Codex tabs.
@Observable
final class CodexAccounts {
    static let shared = CodexAccounts()

    /// The main account first, then the rest in the order they were added.
    private(set) var profiles: [CodexProfile]
    /// Who's signed in to each account, by id. Missing until it's been read.
    private(set) var statuses: [UUID: ClaudeAccount.Status] = [:]
    /// Accounts found on this Mac since you last looked at the list.
    private(set) var newlyFound: [UUID] = []
    private(set) var isScanning = false

    /// Folders you removed, so a scan doesn't add them back.
    @ObservationIgnored private var ignored: Set<String> = []
    @ObservationIgnored private var started = false
    @ObservationIgnored private var timer: Timer?

    private static let file = BenchPaths.support.appendingPathComponent("codex-accounts.json")
    /// Sign-ins change rarely.
    private static let interval: TimeInterval = 30 * 60

    private struct Saved: Codable {
        var profiles: [CodexProfile]
        var ignored: [String]
        var newlyFound: [UUID]?
    }

    private init() {
        var profiles = [CodexProfile.main()]
        if let data = try? Data(contentsOf: Self.file) {
            if let saved = try? JSONDecoder().decode(Saved.self, from: data) {
                if let main = saved.profiles.first(where: \.isMain) { profiles[0].name = main.name }
                profiles += saved.profiles.filter { !$0.isMain }
                ignored = Set(saved.ignored)
                newlyFound = (saved.newlyFound ?? []).filter { id in profiles.contains { $0.id == id } }
            } else {
                BenchPaths.setAside(Self.file)
            }
        }
        self.profiles = profiles
        Self.publish(profiles)
    }

    var main: CodexProfile { profiles[0] }
    /// True once there's more than one account to choose from.
    var hasSeveral: Bool { profiles.count > 1 }

    /// The account with this id, or the main one if it's gone.
    func profile(_ id: UUID?) -> CodexProfile {
        profiles.first { $0.id == id } ?? main
    }

    func status(of id: UUID) -> ClaudeAccount.Status? { statuses[id] }

    /// Where an account sits in the list, for its color.
    func index(of id: UUID) -> Int {
        profiles.firstIndex { $0.id == id } ?? 0
    }

    /// Reads each account's sign-in now and then, and looks for accounts
    /// made outside Workbench. Only once Codex is offered.
    func start() {
        guard !started else { return }
        started = true
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        scan()
    }

    /// Reads every account's sign-in again.
    func refresh() {
        for profile in profiles { refresh(profile.id) }
    }

    /// Reads one account's sign-in again, as after signing in.
    func refresh(_ id: UUID) {
        let profile = profile(id)
        Task {
            let found = await Task.detached(priority: .utility) { Self.readStatus(profile) }.value
            if let found, statuses[profile.id] != found { statuses[profile.id] = found }
        }
    }

    // MARK: Changing the list

    /// Adds an account for `folder`, or returns the one already using it.
    @discardableResult
    func add(name: String, folder: String, madeByWorkbench: Bool) -> CodexProfile {
        if let existing = profiles.first(where: { $0.folder == folder }) { return existing }
        let profile = CodexProfile(id: UUID(), name: name.isEmpty ? Self.name(forFolder: folder) : name,
                                   folder: folder, madeByWorkbench: madeByWorkbench)
        profiles.append(profile)
        ignored.remove(folder)
        save()
        refresh(profile.id)
        return profile
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = profiles.firstIndex(where: { $0.id == id }),
              profiles[index].name != trimmed else { return }
        profiles[index].name = trimmed
        save()
    }

    /// Takes an account off the list. Its folder and sign-in stay where they
    /// are, so it still works in your own terminal.
    func remove(_ id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }), !profiles[index].isMain else { return }
        if let folder = profiles[index].folder { ignored.insert(folder) }
        profiles.remove(at: index)
        statuses[id] = nil
        newlyFound.removeAll { $0 == id }
        save()
    }

    /// You've seen the accounts Workbench found.
    func dismissFound() {
        guard !newlyFound.isEmpty else { return }
        newlyFound = []
        save()
    }

    private func save() {
        Self.publish(profiles)
        let saved = Saved(profiles: profiles, ignored: ignored.sorted(), newlyFound: newlyFound)
        do {
            let data = try JSONEncoder().encode(saved)
            try FileManager.default.createDirectory(at: BenchPaths.support, withIntermediateDirectories: true)
            try data.write(to: Self.file, options: .atomic)
        } catch {
            NSLog("Bench: couldn't save the Codex account list: \(error)")
        }
    }

    // MARK: For code off the main thread

    nonisolated private static let snapshot = Mutex<[CodexProfile]>([.main()])

    /// Every account, readable from any thread, as for reading sessions.
    nonisolated static var all: [CodexProfile] { snapshot.withLock { $0 } }

    private static func publish(_ profiles: [CodexProfile]) {
        snapshot.withLock { $0 = profiles }
    }

    /// The account whose folder holds this session file, or nil if none does.
    nonisolated static func profile(forSession path: String) -> CodexProfile? {
        let file = URL(fileURLWithPath: path).standardizedFileURL.path
        // The longest folder wins, so ~/.codex-work isn't taken for ~/.codex.
        return all.filter { file.hasPrefix($0.sessionsFolder.standardizedFileURL.path + "/") }
            .max { $0.sessionsFolder.path.count < $1.sessionsFolder.path.count }
    }

    // MARK: Who's signed in

    /// An account's sign-in: from its `auth.json` when Codex keeps one, which
    /// names the email and plan, or else from `codex login status`.
    nonisolated static func readStatus(_ profile: CodexProfile) -> ClaudeAccount.Status? {
        let auth = profile.home.appendingPathComponent("auth.json")
        if let data = try? Data(contentsOf: auth), let status = status(fromAuth: data) { return status }
        Tools.resolveIfNeeded()
        guard let codex = Tools.path("codex") else { return nil }
        let command = profile.shellPrefix + shellQuote(codex) + " login status 2>&1"
        guard let output = Tools.runInShell(command, requireSuccess: false) else { return nil }
        return CodexBackground.status(from: output, plan: nil)
    }

    /// What an `auth.json` says: signed in with ChatGPT (with the email and
    /// plan from its id token), with an API key, or not at all.
    nonisolated static func status(fromAuth data: Data) -> ClaudeAccount.Status? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let tokens = object["tokens"] as? [String: Any]
        if let idToken = tokens?["id_token"] as? String, let claims = claims(of: idToken) {
            let auth = claims["https://api.openai.com/auth"] as? [String: Any]
            let plan = (auth?["chatgpt_plan_type"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return ClaudeAccount.Status(loggedIn: true, authMethod: "oauth_token",
                                        subscriptionType: plan ?? "ChatGPT", email: claims["email"] as? String)
        }
        if let key = object["OPENAI_API_KEY"] as? String, !key.isEmpty {
            return ClaudeAccount.Status(loggedIn: true, authMethod: "api_key")
        }
        return ClaudeAccount.Status(loggedIn: false, authMethod: "none")
    }

    /// The claims in a JWT's middle part. Nothing is checked: it's only
    /// read for the email and plan to show.
    nonisolated static func claims(of token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// The command that signs an account in, typed into a small terminal.
    /// With `signingOutFirst`, it signs out of whoever is there first, for
    /// trying again with a different account.
    nonisolated static func loginCommand(_ profile: CodexProfile, signingOutFirst: Bool = false) -> String {
        let codex = shellQuote(Tools.path("codex") ?? "codex")
        return (signingOutFirst ? "\(profile.shellPrefix)\(codex) logout; " : "") + "\(profile.shellPrefix)\(codex) login"
    }

    /// Signs an account out, as when you stop adding it.
    nonisolated static func signOut(_ profile: CodexProfile) {
        guard let codex = Tools.path("codex") else { return }
        _ = Tools.runInShell(profile.shellPrefix + shellQuote(codex) + " logout", requireSuccess: false)
    }

    // MARK: Finding accounts made outside Workbench

    /// Looks for Codex folders on this Mac that are signed in, and adds the
    /// ones Workbench doesn't know yet.
    func scan() {
        guard !isScanning else { return }
        isScanning = true
        let known = Set(profiles.compactMap(\.folder)).union(ignored)
        Task {
            let found = await Task.detached(priority: .utility) { Self.findSignedIn(skipping: known) }.value
            isScanning = false
            var added: [UUID] = []
            for folder in found where !profiles.contains(where: { $0.folder == folder }) && !ignored.contains(folder) {
                added.append(add(name: Self.name(forFolder: folder), folder: folder, madeByWorkbench: false).id)
            }
            if !added.isEmpty {
                newlyFound += added
                save()
            }
        }
    }

    /// Folders that look like Codex's and are signed in.
    nonisolated static func findSignedIn(skipping known: Set<String>) -> [String] {
        candidateFolders().filter { folder in
            !known.contains(folder)
                && readStatus(CodexProfile(id: UUID(), name: "", folder: folder))?.loggedIn == true
        }
    }

    /// Folders named like `~/.codex-work`, and any `CODEX_HOME` set in a
    /// shell profile or alias, that hold a Codex setup.
    nonisolated static func candidateFolders(home: String = NSHomeDirectory(), profileText: [String]? = nil) -> [String] {
        let fm = FileManager.default
        let main = CodexProfile.defaultHome.standardizedFileURL.path
        var folders: [String] = []
        func consider(_ path: String) {
            let expanded = URL(fileURLWithPath: expand(path, home: home)).standardizedFileURL.path
            guard expanded != main, expanded != home + "/.codex", !folders.contains(expanded) else { return }
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue else { return }
            let looksLikeCodex = ["auth.json", "config.toml", "sessions"]
                .contains { fm.fileExists(atPath: (expanded as NSString).appendingPathComponent($0)) }
            if looksLikeCodex { folders.append(expanded) }
        }
        for name in (try? fm.contentsOfDirectory(atPath: home)) ?? [] where name.hasPrefix(".codex") && name != ".codex" {
            consider(home + "/" + name)
        }
        let config = home + "/.config"
        for name in (try? fm.contentsOfDirectory(atPath: config)) ?? [] where name.lowercased().hasPrefix("codex") {
            consider(config + "/" + name)
        }
        for path in profileSettings(home: home, texts: profileText) { consider(path) }
        return folders
    }

    /// Every `CODEX_HOME=…` in the usual shell startup files.
    nonisolated static func profileSettings(home: String = NSHomeDirectory(), texts: [String]? = nil) -> [String] {
        let files = [".zshrc", ".zprofile", ".zshenv", ".bashrc", ".bash_profile", ".profile",
                     ".config/fish/config.fish", ".aliases", ".zsh_aliases", ".bash_aliases"]
        let texts = texts ?? files.compactMap { try? String(contentsOfFile: home + "/" + $0, encoding: .utf8) }
        // CODEX_HOME=~/x, ="~/x", ='~/x', and fish's `set -x CODEX_HOME ~/x`.
        let pattern = #"CODEX_HOME(?:=|\s+)["']?([^"'\s;)`]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var result: [String] = []
        for text in texts {
            for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
                let line = String(line)
                for match in regex.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                    guard let range = Range(match.range(at: 1), in: line) else { continue }
                    let value = String(line[range])
                    if !value.hasPrefix("-"), !result.contains(value) { result.append(value) }
                }
            }
        }
        return result
    }

    /// Expands ~ and $HOME the way the shell does for an unquoted path.
    nonisolated static func expand(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        for variable in ["${HOME}", "$HOME"] where path.hasPrefix(variable) {
            return home + path.dropFirst(variable.count)
        }
        return path
    }

    /// "Work" for `~/.codex-work`, "Account 2" for `~/.codex2`.
    nonisolated static func name(forFolder folder: String) -> String {
        var name = (folder.hasSuffix("/") ? String(folder.dropLast()) : folder)
        name = (name as NSString).lastPathComponent
        for prefix in [".codex", "codex"] where name.lowercased().hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
            break
        }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "-_. "))
        if name.isEmpty || name.allSatisfy(\.isNumber) { return "Account \(name.isEmpty ? "2" : name)" }
        return name.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// A new folder for an account you're adding: `~/.codex-<name>`, or
    /// `~/.codex-<name>-2` if that's taken.
    nonisolated static func newFolder(for name: String) -> String {
        let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { result, c in if !(c == "-" && result.hasSuffix("-")) { result.append(c) } }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let base = NSHomeDirectory() + "/.codex-" + (slug.isEmpty ? "account" : slug)
        var folder = base
        var n = 2
        while FileManager.default.fileExists(atPath: folder) {
            folder = "\(base)-\(n)"
            n += 1
        }
        return folder
    }

    /// What a new account shares with your main one, as links, so a change
    /// to your settings, instructions, or skills shows up in both. The
    /// sign-in and sessions stay the account's own.
    nonisolated static let shareable = ["config.toml", "AGENTS.md", "prompts", "skills", "rules", "plugins", "hooks.json"]

    /// Makes an account's folder, linking in what it should share.
    nonisolated static func makeFolder(_ folder: String, sharing: Bool, main: URL = CodexProfile.defaultHome) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        guard sharing else { return }
        for name in shareable {
            let source = main.appendingPathComponent(name)
            let target = URL(fileURLWithPath: folder).appendingPathComponent(name)
            guard fm.fileExists(atPath: source.path), !fm.fileExists(atPath: target.path) else { continue }
            try? fm.createSymbolicLink(at: target, withDestinationURL: source)
        }
    }
}
