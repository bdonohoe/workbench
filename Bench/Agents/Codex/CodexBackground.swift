import BenchKit
import Foundation

/// Codex run out of sight: `codex exec`, and `codex login status`.
nonisolated struct CodexBackground: AgentBackground {
    var agent: AgentID { .codex }
    var program: String { "codex" }

    /// A question answered from what it's given: your Codex settings
    /// (and so your MCP servers and hooks) are left out, nothing is
    /// saved, and commands can only read.
    func oneShot(instructions: String, model: BackgroundModel, profile: ClaudeProfile) -> BackgroundCommand {
        var arguments = ["exec", "--ephemeral", "--ignore-user-config", "--skip-git-repo-check", "-s", "read-only", "--json"]
        if let small = CodexModelList.small { arguments += ["-m", small] }
        return BackgroundCommand(arguments: arguments + ["-c", "developer_instructions=" + tomlQuote(instructions), "-"])
    }

    /// Codex prints a line of JSON per event. The reply is the last thing
    /// it said, and the tokens are on the line that ends the turn.
    func oneShotReply(in output: String) -> BackgroundReply? {
        var text: String?
        var usage: [String: Any]?
        var failed = false
        var isCodexs = false
        for line in output.split(separator: "\n") {
            guard let event = Self.event(String(line)), let type = event["type"] as? String else { continue }
            isCodexs = true
            switch type {
            case "item.completed":
                if let item = event["item"] as? [String: Any], item["type"] as? String == "agent_message", let said = item["text"] as? String {
                    text = said
                }
            case "turn.completed": usage = event["usage"] as? [String: Any]
            case "turn.failed", "error": failed = true
            default: break
            }
        }
        guard isCodexs else { return nil }
        return BackgroundReply(text: (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines), isError: failed || text == nil,
                               model: CodexModelList.small ?? "codex", usage: usage)
    }

    private static func event(_ line: String) -> [String: Any]? {
        guard line.hasPrefix("{") else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    }

    /// A copy of the session that's thrown away, where commands can only read.
    func sideQuestion(_ prompt: String, sessionID: String, model: String?, profile: ClaudeProfile) -> BackgroundCommand {
        var arguments = ["exec", "fork", sessionID, "--ephemeral", "--json", "-c", #"sandbox_mode="read-only""#]
        if let model { arguments += ["-m", model] }
        return BackgroundCommand(arguments: arguments + [prompt])
    }

    /// Codex gives each thing it says whole, not as it's written.
    func sideQuestionEvent(in line: String) -> SideQuestionStream.Event? {
        guard let event = Self.event(line), let type = event["type"] as? String else { return nil }
        let item = event["item"] as? [String: Any]
        switch type {
        case "item.completed" where item?["type"] as? String == "agent_message":
            return (item?["text"] as? String).map { .text($0) }
        case "item.started" where item?["type"] as? String != "agent_message" && item?["type"] as? String != "reasoning":
            return .toolCall
        case "turn.completed": return .finished(text: "", isError: false)
        case "turn.failed", "error": return .finished(text: "", isError: true)
        default: return nil
        }
    }

    func startsToolCall(_ line: String) -> Bool { sideQuestionEvent(in: line) == .toolCall }

    /// `codex login status` says "Logged in using ChatGPT", "Logged in
    /// using an API key", or "Not logged in".
    func signInStatus(program path: String, folder: String?) -> ClaudeAccount.Status? {
        guard let output = Tools.runInShell("\(shellQuote(path)) login status 2>&1", requireSuccess: false) else { return nil }
        return Self.status(from: output, plan: CodexPlanLimits.latest()?.plan)
    }

    static func status(from output: String, plan: String?) -> ClaudeAccount.Status? {
        let text = output.lowercased()
        if text.contains("not logged in") { return ClaudeAccount.Status(loggedIn: false, authMethod: "none") }
        guard text.contains("logged in") else { return nil }
        if text.contains("api key") { return ClaudeAccount.Status(loggedIn: true, authMethod: "api_key") }
        return ClaudeAccount.Status(loggedIn: true, authMethod: "oauth_token", subscriptionType: plan ?? "ChatGPT")
    }

    var planLimits: (any AgentPlanLimits)? { CodexPlanLimits() }

    /// Codex counts cached tokens inside its input tokens. No cost:
    /// Workbench has no prices for these models yet, and most people use
    /// Codex on a plan.
    func tally(usage: [String: Any], model: String) -> UsageTally {
        func int(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
        let cached = int("cached_input_tokens")
        return UsageTally(requests: 1, input: max(int("input_tokens") - cached, 0), cacheWrite: int("cache_write_input_tokens"),
                          cacheRead: cached, output: int("output_tokens"))
    }
}

/// Codex's plan limits. Codex writes them into a session's file after
/// each reply, so the newest session has the latest.
nonisolated struct CodexPlanLimits: AgentPlanLimits {
    /// Codex's hooks pass no status line.
    func limits(fromStatusLine limits: [String: Any]) -> [PlanLimit] { [] }

    func fetch(profile: ClaudeProfile) async -> PlanLimitsResult {
        guard let latest = Self.latest(), !latest.limits.isEmpty else { return .unavailable }
        return .usage(latest.limits)
    }

    /// The limits in the most recently written session that has any.
    static func latest() -> (limits: [PlanLimit], plan: String?)? {
        let files = CodexSessionIndex.allFiles().compactMap { file -> (URL, Date)? in
            (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { (file, $0) }
        }
        for (file, _) in files.sorted(by: { $0.1 > $1.1 }).prefix(5) {
            if let found = limits(inSession: file) { return found }
        }
        return nil
    }

    static func limits(inSession file: URL) -> (limits: [PlanLimit], plan: String?)? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: end > 512_000 ? end - 512_000 : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        let mark = Data(#""rate_limits""#.utf8)
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() where line.range(of: mark) != nil {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let payload = entry["payload"] as? [String: Any],
                  let limits = payload["rate_limits"] as? [String: Any] else { continue }
            let found = Self.limits(from: limits)
            if !found.isEmpty { return (found, limits["plan_type"] as? String) }
        }
        return nil
    }

    /// `{"primary": {"used_percent": 12, "window_minutes": 300, "resets_at": 1795…}, "secondary": {…}}`
    static func limits(from limits: [String: Any]) -> [PlanLimit] {
        ["primary", "secondary"].compactMap { key in
            guard let entry = limits[key] as? [String: Any],
                  let percent = (entry["used_percent"] as? NSNumber)?.doubleValue else { return nil }
            let minutes = (entry["window_minutes"] as? NSNumber)?.doubleValue ?? (key == "primary" ? 300 : 10080)
            let reset = (entry["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            // Named the way Claude's are, so the rings read the same.
            let isWeek = minutes >= 7 * 24 * 60
            let hours = Int((minutes / 60).rounded())
            return PlanLimit(id: isWeek ? "seven_day" : minutes == 300 ? "five_hour" : "minutes:\(Int(minutes))",
                             name: isWeek ? "This week" : "\(hours) hours", shortName: isWeek ? "Week" : "\(hours)h",
                             percent: percent, resetsAt: reset, window: minutes * 60)
        }
    }
}

/// The models Codex offers, asked of Codex itself (`codex debug models`)
/// so the list keeps up with it. The last answer is kept, and asked for
/// again once each time the app runs.
nonisolated enum CodexModelList {
    static let key = "codexModels"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var loaded: [ModelChoice]?
    nonisolated(unsafe) private static var asked = false

    static var models: [ModelChoice] {
        lock.lock()
        defer { lock.unlock() }
        if loaded == nil {
            loaded = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([ModelChoice].self, from: $0) } ?? []
        }
        // Not from a test run, which shouldn't start Codex.
        if !asked, ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            asked = true
            Task.detached(priority: .utility) { refresh() }
        }
        return loaded ?? []
    }

    /// The quick, cheap one, for a sentence or two. Nil leaves it to Codex.
    static var small: String? { models.first { $0.alias.contains("luna") }?.alias }

    private static func refresh() {
        guard let output = Tools.runInShell("codex debug models 2>/dev/null", timeout: 20) else { return }
        let found = parse(output)
        guard !found.isEmpty else { return }
        lock.lock()
        loaded = found
        lock.unlock()
        if let data = try? JSONEncoder().encode(found) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// The models Codex lists in its own picker, in its order.
    static func parse(_ output: String) -> [ModelChoice] {
        guard let start = output.firstIndex(of: "{"),
              let object = try? JSONSerialization.jsonObject(with: Data(output[start...].utf8)) as? [String: Any],
              let models = object["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { model -> ModelChoice? in
            guard let slug = model["slug"] as? String, model["visibility"] as? String == "list" else { return nil }
            var summary = model["description"] as? String ?? ""
            if summary.hasSuffix(".") { summary.removeLast() }
            return ModelChoice(alias: slug, name: CodexModels.name(slug), summary: summary)
        }
    }
}
