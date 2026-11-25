import Foundation
import Observation

/// How one Claude account pays for what it does, from `claude auth
/// status`: a Claude plan with usage limits, or an API key or cloud
/// provider that bills by the token. There's one for each account in
/// `ClaudeAccounts`; `shared` is the main one.
///
/// Read through the login shell, the same way a terminal tab runs Claude,
/// because an API key usually lives in the shell profile
/// (`ANTHROPIC_API_KEY`) where Workbench itself can't see it.
@Observable
final class ClaudeAccount {
    static var shared: ClaudeAccount { ClaudeAccounts.shared.account(for: ClaudeProfile.mainID) }

    /// The account's `CLAUDE_CONFIG_DIR`, or nil for the main one.
    let folder: String?

    nonisolated enum Billing: String, Codable, Sendable {
        /// Signed in to a Claude plan (Pro, Max, Team, Enterprise).
        case plan
        /// An Anthropic API key, or a cloud provider like Bedrock or Vertex.
        case perToken
    }

    /// What `claude auth status` said, boiled down.
    nonisolated struct Status: Codable, Equatable, Sendable {
        var loggedIn: Bool
        /// "claude.ai", "api_key", "api_key_helper", "oauth_token", "third_party", "none".
        var authMethod: String?
        /// "firstParty", "bedrock", "vertex", "foundry", "gateway", ...
        var apiProvider: String?
        /// "pro", "max", "team", "enterprise" for a Claude plan.
        var subscriptionType: String?
        /// The signed-in account's email, for telling accounts apart.
        var email: String?

        /// "Max", "Pro", "Team", or nil.
        var planName: String? {
            guard let subscriptionType, !subscriptionType.isEmpty else { return nil }
            return subscriptionType.prefix(1).uppercased() + subscriptionType.dropFirst()
        }

        /// "Max plan", "API key", "Amazon Bedrock", or "Signed out".
        var summary: String {
            guard loggedIn else { return "Signed out" }
            if let providerName { return providerName }
            if billing == .perToken { return "API key" }
            return planName.map { "\($0) plan" } ?? "Claude plan"
        }

        var billing: Billing? {
            guard loggedIn else { return nil }
            if let apiProvider, apiProvider != "firstParty", apiProvider != "gateway" { return .perToken }
            switch authMethod {
            case "api_key", "api_key_helper", "third_party": return .perToken
            case "claude.ai", "oauth_token": return .plan
            default: return nil
            }
        }

        /// "Bedrock", "Vertex AI", or nil for Anthropic's own API.
        var providerName: String? {
            switch apiProvider {
            case "bedrock": "Amazon Bedrock"
            case "vertex": "Google Vertex AI"
            case "foundry": "Microsoft Foundry"
            case nil, "firstParty", "gateway": nil
            case let other?: other
            }
        }

        /// Reads the JSON `claude auth status` prints. Nil if there's none.
        static func parse(_ output: String) -> Status? {
            guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end,
                  let object = try? JSONSerialization.jsonObject(with: Data(output[start...end].utf8)) as? [String: Any],
                  let loggedIn = object["loggedIn"] as? Bool else { return nil }
            return Status(loggedIn: loggedIn, authMethod: object["authMethod"] as? String,
                          apiProvider: object["apiProvider"] as? String,
                          subscriptionType: object["subscriptionType"] as? String,
                          email: object["email"] as? String)
        }
    }

    /// Nil until the first check comes back (the last answer is kept from
    /// one launch to the next, so that's rare).
    private(set) var status: Status?

    var billing: Billing? {
        #if DEBUG
        // BENCH_BILLING=perToken or plan pretends, for testing.
        if let forced = ProcessInfo.processInfo.environment["BENCH_BILLING"].flatMap(Billing.init(rawValue:)) { return forced }
        #endif
        return status?.billing
    }

    var paysPerToken: Bool { billing == .perToken }

    @ObservationIgnored private var checking = false
    @ObservationIgnored private var lastCheck = Date.distantPast
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let savedKey: String
    /// Sign-ins change rarely; a new API key in the profile shows up within this.
    private static let interval: TimeInterval = 30 * 60

    init(profile: ClaudeProfile) {
        folder = profile.folder
        savedKey = profile.isMain ? "claudeAccountStatus" : "claudeAccountStatus.\(profile.id.uuidString)"
        if let data = UserDefaults.standard.data(forKey: savedKey) {
            status = try? JSONDecoder().decode(Status.self, from: data)
        }
        #if DEBUG
        if let json = ProcessInfo.processInfo.environment[Self.pretendStatusKey] { status = Status.parse(json) }
        #endif
    }

    #if DEBUG
    /// BENCH_AUTH_STATUS=<what `claude auth status --json` would print>
    /// pretends to be that account, for testing.
    nonisolated static let pretendStatusKey = "BENCH_AUTH_STATUS"
    #endif

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        check()
    }

    /// Checks again unless it did in the last minute, as when Usage opens.
    func checkSoon() {
        guard Date().timeIntervalSince(lastCheck) > 60 else { return }
        check()
    }

    /// Checks again now, as after signing in.
    func checkNow() {
        check()
    }

    private func check() {
        #if DEBUG
        if ProcessInfo.processInfo.environment[Self.pretendStatusKey] != nil { return }
        #endif
        guard !checking else { return }
        checking = true
        lastCheck = .now
        let folder = folder
        Task {
            let found = await Task.detached(priority: .utility) { Self.read(folder: folder) }.value
            checking = false
            guard let found, found != status else { return }
            status = found
            if let data = try? JSONEncoder().encode(found) {
                UserDefaults.standard.set(data, forKey: self.savedKey)
            }
        }
    }

    /// Runs `claude auth status` in the login shell. Nil when Claude Code
    /// isn't installed or is too old to have the command.
    nonisolated static func read(folder: String? = nil) -> Status? {
        Tools.resolveIfNeeded()
        guard let claude = Tools.path("claude") else { return nil }
        return read(claude: claude, folder: folder)
    }

    /// With a folder, asks about the account kept there instead.
    nonisolated static func read(claude: String, folder: String? = nil) -> Status? {
        Agents.background(.claude).signInStatus(program: claude, folder: folder)
    }
}
