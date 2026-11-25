import BenchKit
import Foundation

extension UsageLedger {
    /// The Usage page's last 30 days, for the phone. Nil until the logs
    /// have been read once.
    func companionUsage(now: Date = .now) -> CompanionUsage? {
        guard lastScan != nil, !buckets.isEmpty else { return nil }
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let today = calendar.startOfDay(for: now)
        let dayNames = (0..<30).reversed().map { formatter.string(from: calendar.date(byAdding: .day, value: -$0, to: today)!) }
        let inRange = Set(dayNames)

        var days: [String: CompanionUsage.Day] = [:]
        var models: [String: UsageTally] = [:]
        var total = UsageTally()
        for (bucket, tally) in buckets where inRange.contains(bucket.day) {
            let family = ModelFamily(model: bucket.model).name
            var day = days[bucket.day] ?? CompanionUsage.Day(day: bucket.day, cost: [:], tokens: 0)
            day.cost[family, default: 0] += tally.cost
            day.tokens += tally.totalTokens
            days[bucket.day] = day
            models[bucket.model, default: UsageTally()] += tally
            total += tally
        }
        let modelList = models.sorted { $0.value.cost > $1.value.cost }.map { id, tally in
            CompanionUsage.Model(name: ContextUsage.modelName(id), family: ModelFamily(model: id).name,
                                 cost: tally.cost, tokens: tally.totalTokens)
        }
        return CompanionUsage(days: dayNames.map { days[$0] ?? CompanionUsage.Day(day: $0, cost: [:], tokens: 0) },
                              models: modelList, cacheSavings: max(total.uncachedCost - total.cost, 0),
                              updated: lastScan ?? now, paysPerToken: ClaudeAccount.shared.billing.map { $0 == .perToken },
                              provider: ClaudeAccount.shared.status?.providerName)
    }
}
