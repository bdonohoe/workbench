import Foundation

/// How much of a Claude plan's limits you've used: the 5-hour window, the
/// week, and any per-model weekly limit like Fable's.
public struct PlanUsage: Codable, Sendable, Hashable {
    public var limits: [PlanLimit]
    /// When the newest of these numbers came in.
    public var updated: Date

    public init(limits: [PlanLimit], updated: Date) {
        self.limits = limits
        self.updated = updated
    }
}

/// One limit, like "5 hours" or "Fable".
public struct PlanLimit: Codable, Sendable, Hashable, Identifiable {
    /// "five_hour", "seven_day", or "model:fable".
    public var id: String
    /// "5 hours", "This week", "Fable".
    public var name: String
    /// What it's called under its ring: "5h", "Week", "Fable".
    public var shortName: String
    /// 0 to 100.
    public var percent: Double
    public var resetsAt: Date?
    /// How long the whole window lasts, for how far into it you are.
    public var window: TimeInterval
    /// True for a limit on one model rather than on everything.
    public var isPerModel: Bool
    /// For money rather than a share of a plan: what's been spent in this
    /// window, in dollars. Set on the monthly spending limit of an API key
    /// or cloud account. Older phones ignore it and show the percentage.
    public var dollars: Double?
    /// The budget `dollars` counts toward, when there is one. `percent`
    /// is `dollars` as a share of it, or 0 without one.
    public var budget: Double?

    public init(id: String, name: String, shortName: String, percent: Double, resetsAt: Date?,
                window: TimeInterval, isPerModel: Bool = false, dollars: Double? = nil, budget: Double? = nil) {
        self.id = id
        self.name = name
        self.shortName = shortName
        self.percent = percent
        self.resetsAt = resetsAt
        self.window = window
        self.isPerModel = isPerModel
        self.dollars = dollars
        self.budget = budget
    }

    public static let fiveHours: TimeInterval = 5 * 3600
    public static let week: TimeInterval = 7 * 86400
    /// The id of the monthly spending limit.
    public static let monthSpendID = "month_spend"

    /// True for a limit counted in dollars.
    public var isSpend: Bool { dollars != nil }

    /// "$142", or "$1.2k" past $10,000 so it fits under a small ring.
    public static func shortDollars(_ value: Double) -> String {
        if value >= 10_000 { return String(format: "$%.1fk", value / 1000) }
        if value >= 100 || value == 0 { return dollarText(value.rounded()) }
        return String(format: "$%.2f", value)
    }

    /// Dollars as people write them: "$1,240", "$38.20".
    public static func dollarText(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.locale = Locale(identifier: "en_US")
        formatter.maximumFractionDigits = value >= 1000 || value == value.rounded() ? 0 : 2
        formatter.minimumFractionDigits = formatter.maximumFractionDigits
        return formatter.string(from: NSNumber(value: value)) ?? "$\(Int(value))"
    }

    /// One short line for a strip: "Week 52%", or "$142 of $500" and
    /// "$142 this month" for spending.
    public func summary(at now: Date) -> String {
        guard let dollars else { return "\(shortName) \(Int(percent(at: now).rounded()))%" }
        let spent = Self.shortDollars(resetsAt.map { $0 <= now } == true ? 0 : dollars)
        return budget.map { "\(spent) of \(Self.shortDollars($0))" } ?? "\(spent) this month"
    }

    /// A monthly spending limit: the calendar month so far, ending at the
    /// start of the next one, in the Mac's time zone.
    public static func monthSpend(dollars: Double, budget: Double?, now: Date = .now, calendar: Calendar = .current) -> PlanLimit {
        let start = calendar.dateInterval(of: .month, for: now)
        let percent = budget.map { $0 > 0 ? dollars / $0 * 100 : 0 } ?? 0
        return PlanLimit(id: monthSpendID, name: "This month", shortName: shortDollars(dollars), percent: percent,
                         resetsAt: start?.end, window: start?.duration ?? 30 * 86400, dollars: dollars, budget: budget)
    }

    /// What's used as of `now`. A window that has reset since the numbers
    /// came in starts over at zero.
    public func percent(at now: Date) -> Double {
        if let resetsAt, resetsAt <= now { return 0 }
        return min(max(percent, 0), 100)
    }

    /// How far through the window `now` is, from 0 to 1. Nil once the
    /// window has reset, since the next one's start isn't known yet.
    public func elapsed(at now: Date) -> Double? {
        guard let resetsAt, resetsAt > now, window > 0 else { return nil }
        return min(max(1 - resetsAt.timeIntervalSince(now) / window, 0), 1)
    }

    /// "1h 12m", "2d 9h", "38m". Nil when the reset time isn't known.
    public func timeLeft(at now: Date) -> String? {
        guard let resetsAt, resetsAt > now else { return nil }
        return Self.shortDuration(resetsAt.timeIntervalSince(now))
    }

    public static func shortDuration(_ seconds: TimeInterval) -> String {
        let minutes = max(Int(seconds / 60), 1)
        let days = minutes / 1440, hours = minutes % 1440 / 60, mins = minutes % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }
}

extension PlanUsage {
    /// Whether an account that doesn't say it pays per token should still
    /// show its month's spending, rather than nothing. `claude auth status`
    /// reports a gateway's `ANTHROPIC_AUTH_TOKEN` as a plan-style sign-in
    /// with no subscription, and some Team and Enterprise plans are billed
    /// by usage and have no limits. Pro and Max always have limits, so they
    /// wait for them instead.
    public static func showsSpendInstead(loggedIn: Bool, subscriptionType: String?, hasRecentLimits: Bool) -> Bool {
        guard loggedIn, !hasRecentLimits else { return false }
        return !["pro", "max"].contains(subscriptionType?.lowercased() ?? "")
    }
}
