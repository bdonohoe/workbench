import BenchKit
import CryptoKit
import Foundation
import Observation
import Synchronization

/// One Claude Code sign-in that Workbench can start Claude tabs with.
///
/// Claude Code keeps an account's sign-in, settings, and past sessions in
/// one folder: `~/.claude` normally, or whatever `CLAUDE_CONFIG_DIR` names.
/// So a second account is just a second folder. Workbench's main account
/// leaves `CLAUDE_CONFIG_DIR` alone; every other one sets it.
nonisolated struct ClaudeProfile: Codable, Identifiable, Hashable, Sendable {
    /// The main account, the one Claude Code uses without being told.
    static let mainID = UUID(uuidString: "00000000-0000-0000-0000-00000000C1A0")!

    var id: UUID
    var name: String
    /// What `CLAUDE_CONFIG_DIR` is set to, exactly as written: Claude Code
    /// names the account's Keychain item after this string, so "~/x/" and
    /// "~/x" are different sign-ins. Nil for the main account.
    var folder: String?
    /// True when Workbench made the folder, rather than finding it.
    var madeByWorkbench: Bool?

    var isMain: Bool { folder == nil }

    static func main(named name: String = "Main") -> ClaudeProfile {
        ClaudeProfile(id: mainID, name: name, folder: nil)
    }

    /// The account's folder on disk.
    var configURL: URL {
        if let folder { return URL(fileURLWithPath: (folder as NSString).expandingTildeInPath) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    }

    /// Where Claude Code keeps this account's session transcripts.
    var projectsURL: URL { configURL.appendingPathComponent("projects", isDirectory: true) }

    /// The Keychain item Claude Code keeps this account's sign-in in. With
    /// `CLAUDE_CONFIG_DIR` set, its name ends in the first 8 hex digits of
    /// the SHA-256 of that setting.
    var keychainService: String {
        guard let folder else { return "Claude Code-credentials" }
        let digest = SHA256.hash(data: Data(folder.precomposedStringWithCanonicalMapping.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-\(hex.prefix(8))"
    }

    /// Where Bench's status line step saves this account's plan numbers.
    var statusFile: URL {
        isMain ? BenchPaths.support.appendingPathComponent("claude-status.json")
            : BenchPaths.support.appendingPathComponent("claude-status-\(id.uuidString).json")
    }

    /// What to type before `claude` to use this account. Empty for the main one.
    var shellPrefix: String {
        guard let folder else { return "" }
        return "CLAUDE_CONFIG_DIR=\(Self.quote(folder)) "
    }

    /// The folder as people write it, with ~ for the home folder.
    var displayFolder: String {
        guard let folder else { return "~/.claude" }
        let home = NSHomeDirectory()
        return folder.hasPrefix(home + "/") ? "~" + folder.dropFirst(home.count) : folder
    }

    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}

/// The Claude accounts Workbench knows: the main one, plus any others it
/// found on this Mac or you added. Each project picks one.
@Observable
final class ClaudeAccounts {
    static let shared = ClaudeAccounts()

    /// The main account first, then the rest in the order they were added.
    private(set) var profiles: [ClaudeProfile]
    /// Accounts found on this Mac since you last looked at the list, for
    /// the "Workbench found…" note.
    private(set) var newlyFound: [UUID] = []
    private(set) var isScanning = false

    @ObservationIgnored private var accounts: [UUID: ClaudeAccount] = [:]
    @ObservationIgnored private var monitors: [UUID: PlanUsageMonitor] = [:]
    /// Folders you removed, so a scan doesn't add them back.
    @ObservationIgnored private var ignored: Set<String> = []
    @ObservationIgnored private var started = false

    private static let file = BenchPaths.support.appendingPathComponent("claude-accounts.json")

    private struct Saved: Codable {
        var profiles: [ClaudeProfile]
        var ignored: [String]
        var newlyFound: [UUID]?
    }

    private init() {
        var profiles = [ClaudeProfile.main()]
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
        #if DEBUG
        // BENCH_EXTRA_ACCOUNT=<folder> adds a second account, for testing.
        if let folder = ProcessInfo.processInfo.environment["BENCH_EXTRA_ACCOUNT"], !folder.isEmpty,
           !profiles.contains(where: { $0.folder == folder }) {
            self.profiles.append(ClaudeProfile(id: UUID(), name: Self.name(forFolder: folder), folder: folder))
            Self.publish(self.profiles)
        }
        #endif
    }

    var main: ClaudeProfile { profiles[0] }
    var others: [ClaudeProfile] { Array(profiles.dropFirst()) }
    /// True once there's more than one account to choose from.
    var hasSeveral: Bool { profiles.count > 1 }

    /// The account with this id, or the main one if it's gone.
    func profile(_ id: UUID?) -> ClaudeProfile {
        profiles.first { $0.id == id } ?? main
    }

    /// The account whose folder holds this session transcript, or the main one.
    func profile(forTranscript path: String) -> ClaudeProfile {
        TranscriptOwner.index(of: path, amongProjectFolders: profiles.map(\.projectsURL.path)).map { profiles[$0] } ?? main
    }

    /// Checks each account's sign-in now and then, and looks for accounts
    /// made outside Workbench.
    func start() {
        guard !started else { return }
        started = true
        for profile in profiles { account(for: profile.id).start() }
        for profile in profiles { monitor(for: profile.id).start() }
        scan()
    }

    /// Who's signed in to an account, and how it pays.
    func account(for id: UUID?) -> ClaudeAccount {
        let profile = profile(id)
        if let existing = accounts[profile.id] { return existing }
        let account = ClaudeAccount(profile: profile)
        accounts[profile.id] = account
        if started { account.start() }
        return account
    }

    /// An account's plan limits or spending.
    func monitor(for id: UUID?) -> PlanUsageMonitor {
        let profile = profile(id)
        if let existing = monitors[profile.id] { return existing }
        let monitor = PlanUsageMonitor(profile: profile, account: account(for: profile.id))
        monitors[profile.id] = monitor
        if started { monitor.start() }
        return monitor
    }

    // MARK: Changing the list

    /// Adds an account for `folder`, or returns the one already using it.
    @discardableResult
    func add(name: String, folder: String, madeByWorkbench: Bool) -> ClaudeProfile {
        if let existing = profiles.first(where: { $0.folder == folder }) { return existing }
        let profile = ClaudeProfile(id: UUID(), name: name.isEmpty ? Self.name(forFolder: folder) : name,
                                    folder: folder, madeByWorkbench: madeByWorkbench)
        profiles.append(profile)
        ignored.remove(folder)
        save()
        _ = account(for: profile.id)
        _ = monitor(for: profile.id)
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
        newlyFound.removeAll { $0 == id }
        accounts[id] = nil
        monitors[id]?.stop()
        monitors[id] = nil
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
            // Silent, this is an account that vanishes on the next launch.
            NSLog("Bench: couldn't save the account list: \(error)")
        }
    }

    // MARK: For code off the main thread

    nonisolated private static let snapshot = Mutex<[ClaudeProfile]>([.main()])

    /// Every account, readable from any thread, as for reading transcripts.
    nonisolated static var all: [ClaudeProfile] { snapshot.withLock { $0 } }

    private static func publish(_ profiles: [ClaudeProfile]) {
        snapshot.withLock { $0 = profiles }
    }

    // MARK: Finding accounts made outside Workbench

    /// Looks for Claude Code folders on this Mac that are signed in, and
    /// adds the ones Workbench doesn't know yet.
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
                Analytics.capture(.claudeAccountsFound, ["count": added.count])
            }
        }
    }

    /// Folders that look like Claude Code's and are signed in.
    nonisolated static func findSignedIn(skipping known: Set<String>) -> [String] {
        Tools.resolveIfNeeded()
        guard let claude = Tools.path("claude") else { return [] }
        var result: [String] = []
        for folder in candidateFolders() where !known.contains(folder) {
            // The Keychain item is named after the exact string, so try it
            // with and without a trailing slash.
            let variants = folder.hasSuffix("/") ? [folder, String(folder.dropLast())] : [folder, folder + "/"]
            for variant in variants where !known.contains(variant) {
                if ClaudeAccount.read(claude: claude, folder: variant)?.loggedIn == true {
                    result.append(variant)
                    break
                }
            }
        }
        return result
    }

    /// Folders named like `~/.claude-work`, and any `CLAUDE_CONFIG_DIR` set
    /// in a shell profile or alias, that hold a Claude Code setup.
    nonisolated static func candidateFolders() -> [String] {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let main = home + "/.claude"
        var folders: [String] = []
        func consider(_ path: String) {
            let expanded = expand(path)
            guard expanded != main, expanded != main + "/", !folders.contains(expanded) else { return }
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue else { return }
            let looksLikeClaude = [".claude.json", "projects", "settings.json", ".credentials.json"]
                .contains { fm.fileExists(atPath: (expanded as NSString).appendingPathComponent($0)) }
            if looksLikeClaude { folders.append(expanded) }
        }
        for name in (try? fm.contentsOfDirectory(atPath: home)) ?? [] where name.hasPrefix(".claude") && name != ".claude" {
            consider(home + "/" + name)
        }
        let config = home + "/.config"
        for name in (try? fm.contentsOfDirectory(atPath: config)) ?? [] where name.lowercased().hasPrefix("claude") {
            consider(config + "/" + name)
        }
        for path in profileSettings() { consider(path) }
        return folders
    }

    /// Every `CLAUDE_CONFIG_DIR=…` in the usual shell startup files.
    nonisolated static func profileSettings() -> [String] {
        let home = NSHomeDirectory()
        let files = [".zshrc", ".zprofile", ".zshenv", ".bashrc", ".bash_profile", ".profile",
                     ".config/fish/config.fish", ".aliases", ".zsh_aliases", ".bash_aliases"]
        // CLAUDE_CONFIG_DIR=~/x, ="~/x", ='~/x', and fish's `set -x CLAUDE_CONFIG_DIR ~/x`.
        let pattern = #"CLAUDE_CONFIG_DIR(?:=|\s+)["']?([^"'\s;)`]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var result: [String] = []
        for file in files {
            guard let text = try? String(contentsOfFile: home + "/" + file, encoding: .utf8) else { continue }
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
    nonisolated static func expand(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        for variable in ["${HOME}", "$HOME"] where path.hasPrefix(variable) {
            return home + path.dropFirst(variable.count)
        }
        return path
    }

    /// "Work" for `~/.claude-work`, "Account 2" for `~/.claude2`.
    nonisolated static func name(forFolder folder: String) -> String {
        var name = (folder.hasSuffix("/") ? String(folder.dropLast()) : folder)
        name = (name as NSString).lastPathComponent
        for prefix in [".claude", "claude"] where name.lowercased().hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
            break
        }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "-_. "))
        if name.isEmpty || name.allSatisfy(\.isNumber) { return "Account \(name.isEmpty ? "2" : name)" }
        return name.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// A new folder for an account you're adding: `~/.claude-<name>`, or
    /// `~/.claude-<name>-2` if that's taken.
    nonisolated static func newFolder(for name: String) -> String {
        let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { result, c in if !(c == "-" && result.hasSuffix("-")) { result.append(c) } }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let base = NSHomeDirectory() + "/.claude-" + (slug.isEmpty ? "account" : slug)
        var folder = base
        var n = 2
        while FileManager.default.fileExists(atPath: folder) {
            folder = "\(base)-\(n)"
            n += 1
        }
        return folder
    }

    /// What a new account shares with your main one, as links, so a change
    /// to your settings or skills shows up in both.
    nonisolated static let shareable = ["settings.json", "CLAUDE.md", "commands", "agents", "skills",
                                        "output-styles", "plugins", "keybindings.json", "hooks"]

    /// Makes an account's folder, linking in what it should share.
    nonisolated static func makeFolder(_ folder: String, sharing: Bool) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        guard sharing else { return }
        let main = ClaudeProfile.main().configURL
        for name in shareable {
            let source = main.appendingPathComponent(name)
            let target = URL(fileURLWithPath: folder).appendingPathComponent(name)
            guard fm.fileExists(atPath: source.path), !fm.fileExists(atPath: target.path) else { continue }
            try? fm.createSymbolicLink(at: target, withDestinationURL: source)
        }
    }
}
