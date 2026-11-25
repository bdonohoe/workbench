import BenchKit
import Foundation

/// Where a Claude plan's limits come from: the status line Claude Code
/// passes its hooks, and the account's usage endpoint, asked with the
/// sign-in Claude Code keeps in the Keychain.
nonisolated struct ClaudePlanLimits: AgentPlanLimits {
    func limits(fromStatusLine limits: [String: Any]) -> [PlanLimit] { Self.statusLimits(limits) }

    static func statusLimits(_ limits: [String: Any]) -> [PlanLimit] {
        func limit(_ key: String) -> (Double, Date?)? {
            guard let entry = limits[key] as? [String: Any],
                  let percent = (entry["used_percentage"] as? NSNumber)?.doubleValue else { return nil }
            let reset = (entry["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return (percent, reset)
        }
        var result: [PlanLimit] = []
        if let (percent, reset) = limit("five_hour") {
            result.append(PlanLimit(id: "five_hour", name: "5 hours", shortName: "5h", percent: percent,
                                    resetsAt: reset, window: PlanLimit.fiveHours))
        }
        if let (percent, reset) = limit("seven_day") {
            result.append(PlanLimit(id: "seven_day", name: "This week", shortName: "Week", percent: percent,
                                    resetsAt: reset, window: PlanLimit.week))
        }
        return result
    }

    // MARK: The account's usage endpoint

    func fetch(profile: ClaudeProfile) async -> PlanLimitsResult {
        let keychainService = profile.keychainService
        #if DEBUG
        // A pretend account shouldn't pick up this Mac's real sign-in.
        if ProcessInfo.processInfo.environment[ClaudeAccount.pretendStatusKey] != nil { return .unavailable }
        #endif
        guard let token = await Task.detached(operation: { Self.accessToken(service: keychainService) }).value,
              let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else { return .unavailable }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("Bench", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return .unavailable }
        if http.statusCode == 429 {
            return .rateLimited(retryAfter: http.value(forHTTPHeaderField: "retry-after").flatMap(TimeInterval.init))
        }
        guard http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .unavailable }
        return .usage(Self.accountLimits(json))
    }

    /// An account's Claude Code sign-in, from the Keychain item it keeps.
    /// Read with `security`, as Claude Code itself does, so there's no prompt.
    private static func accessToken(service: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        return token
    }

    /// The endpoint lists limits as `limits: [{scope, percent, resets_at}]`,
    /// where a per-model limit's scope names its model. Older responses
    /// had `five_hour`, `seven_day`, and `seven_day_<model>` objects with a
    /// `utilization`; both are read.
    static func accountLimits(_ json: [String: Any]) -> [PlanLimit] {
        var result: [PlanLimit] = []
        func add(id: String, name: String, short: String, percent: Double, reset: Date?, window: TimeInterval, perModel: Bool) {
            guard !result.contains(where: { $0.id == id }) else { return }
            result.append(PlanLimit(id: id, name: name, shortName: short, percent: percent, resetsAt: reset,
                                    window: window, isPerModel: perModel))
        }
        for entry in json["limits"] as? [[String: Any]] ?? [] {
            guard let percent = (entry["percent"] as? NSNumber)?.doubleValue,
                  let scope = entry["scope"] as? [String: Any],
                  let model = scope["model"] as? [String: Any],
                  let name = model["display_name"] as? String, !name.isEmpty else { continue }
            let title = name.prefix(1).uppercased() + name.dropFirst()
            add(id: "model:\(name.lowercased())", name: title, short: title, percent: percent,
                reset: date(entry["resets_at"]), window: PlanLimit.week, perModel: true)
        }
        for (key, value) in json {
            guard let entry = value as? [String: Any],
                  let percent = (entry["utilization"] as? NSNumber)?.doubleValue else { continue }
            let reset = date(entry["resets_at"])
            switch key {
            case "five_hour":
                add(id: key, name: "5 hours", short: "5h", percent: percent, reset: reset, window: PlanLimit.fiveHours, perModel: false)
            case "seven_day":
                add(id: key, name: "This week", short: "Week", percent: percent, reset: reset, window: PlanLimit.week, perModel: false)
            case let key where key.hasPrefix("seven_day_"):
                let model = String(key.dropFirst("seven_day_".count))
                guard !["oauth_apps", "cowork"].contains(model) else { continue }
                let title = model.prefix(1).uppercased() + model.dropFirst()
                add(id: "model:\(model)", name: title, short: title, percent: percent, reset: reset, window: PlanLimit.week, perModel: true)
            default:
                continue
            }
        }
        return result
    }

    private static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber { return Date(timeIntervalSince1970: number.doubleValue) }
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
