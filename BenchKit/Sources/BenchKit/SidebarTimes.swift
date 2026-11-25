import Foundation

/// How long a project stays in the sidebar's Active section after you last
/// use it, and when it moves on to Inactive. In between, it's in Recent.
/// Someone who works in a project every few days can stretch both, so it
/// doesn't drop to Inactive (and lose its tabs) between visits.
public struct SidebarTimes: Equatable, Sendable {
    /// Used within this long, a project is under Active.
    public var active: TimeInterval
    /// Not used for this long, it's under Inactive. Always longer than
    /// `active`, so Recent is never empty by design.
    public var inactiveAfter: TimeInterval

    public init(active: TimeInterval, inactiveAfter: TimeInterval) {
        self.active = active
        self.inactiveAfter = inactiveAfter
    }

    private static let hour: TimeInterval = 3600
    private static let day: TimeInterval = 24 * hour

    public static let standard = SidebarTimes(active: 6 * hour, inactiveAfter: day)

    public static let activeChoices: [TimeInterval] = [hour, 3 * hour, 6 * hour, 12 * hour, day, 3 * day]
    public static let inactiveChoices: [TimeInterval] = [day, 3 * day, 7 * day, 14 * day, 30 * day]

    /// The Inactive choices that leave room for Recent after `active`.
    public static func inactiveChoices(after active: TimeInterval) -> [TimeInterval] {
        inactiveChoices.filter { $0 > active }
    }

    /// The same times with Inactive pushed out past Active when the two
    /// would overlap, to the nearest choice that fits.
    public var fitted: SidebarTimes {
        guard inactiveAfter <= active else { return self }
        let later = Self.inactiveChoices(after: active).first ?? active * 2
        return SidebarTimes(active: active, inactiveAfter: later)
    }

    // MARK: Saved

    public static let activeKey = "sidebarActiveFor"
    public static let inactiveKey = "sidebarInactiveAfter"

    /// The saved times, or the standard ones.
    public static func saved(in defaults: UserDefaults = .standard) -> SidebarTimes {
        let active = defaults.double(forKey: activeKey)
        let inactive = defaults.double(forKey: inactiveKey)
        return SidebarTimes(active: active > 0 ? active : standard.active,
                            inactiveAfter: inactive > 0 ? inactive : standard.inactiveAfter).fitted
    }

    public func save(in defaults: UserDefaults = .standard) {
        defaults.set(active, forKey: Self.activeKey)
        defaults.set(inactiveAfter, forKey: Self.inactiveKey)
    }

    // MARK: Words

    /// A length of time as a menu shows it: "6 hours", "1 day", "1 week".
    public static func name(_ interval: TimeInterval) -> String {
        let days = interval / day
        if days >= 28 && days.truncatingRemainder(dividingBy: 30) == 0 {
            let months = Int(days / 30)
            return months == 1 ? "1 month" : "\(months) months"
        }
        if days >= 7 && days.truncatingRemainder(dividingBy: 7) == 0 {
            let weeks = Int(days / 7)
            return weeks == 1 ? "1 week" : "\(weeks) weeks"
        }
        if days >= 1 && days.truncatingRemainder(dividingBy: 1) == 0 {
            return days == 1 ? "1 day" : "\(Int(days)) days"
        }
        let hours = Int((interval / hour).rounded())
        return hours == 1 ? "1 hour" : "\(hours) hours"
    }

    /// The quiet words beside Recent: how far back it reaches, like
    /// "Last day" or "Last 2 weeks".
    public static func recentHint(inactiveAfter: TimeInterval) -> String {
        let words = name(inactiveAfter)
        return "Last " + (words.hasPrefix("1 ") ? String(words.dropFirst(2)) : words)
    }

    public var recentHint: String { Self.recentHint(inactiveAfter: inactiveAfter) }
}
