import Foundation

/// Slows down token guessing on the home network listener: five bad
/// hellos from one address within a minute and that address is ignored
/// for five minutes.
public struct HelloThrottle {
    public static let limit = 5
    public static let window: TimeInterval = 60
    public static let blockFor: TimeInterval = 300

    private var failures: [String: [Date]] = [:]
    private var blockedUntil: [String: Date] = [:]

    public init() {}

    public mutating func failed(from address: String, at date: Date) {
        forgetStale(at: date)
        var recent = (failures[address] ?? []).filter { date.timeIntervalSince($0) < Self.window }
        recent.append(date)
        if recent.count >= Self.limit {
            blockedUntil[address] = date + Self.blockFor
            failures[address] = nil
        } else {
            failures[address] = recent
        }
    }

    public func isBlocked(_ address: String, at date: Date) -> Bool {
        guard let until = blockedUntil[address] else { return false }
        return date < until
    }

    /// Keeps the tables from growing with every address that ever failed once.
    private mutating func forgetStale(at date: Date) {
        blockedUntil = blockedUntil.filter { date < $0.value }
        failures = failures.filter { entry in entry.value.contains { date.timeIntervalSince($0) < Self.window } }
    }
}
