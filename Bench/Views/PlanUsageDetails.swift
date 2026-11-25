import BenchKit
import SwiftUI

/// Each limit with a bar, its percentage, and when it resets. Part of the
/// card at the foot of the sidebar, which sets the padding.
struct PlanUsageDetails: View {
    let usage: PlanUsage
    let showsPace: Bool
    /// Whose usage this is. Named in the heading once there's more than one.
    var accountID = ClaudeProfile.mainID
    let openUsage: () -> Void
    /// Opens Settings > Claude Accounts.
    var openAccounts: (() -> Void)?

    private var accounts: ClaudeAccounts { .shared }

    var body: some View {
        if let spend = usage.limits.first(where: \.isSpend) {
            SpendDetails(limit: spend, updated: usage.updated, showsPace: showsPace, accountID: accountID, openUsage: openUsage)
        } else {
            planBody
        }
    }

    /// "Plan usage", or "Work: Pro plan" with several accounts.
    private var heading: some View {
        AccountHeading(title: "Plan usage", accountID: accountID)
    }

    private var planBody: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date
            VStack(alignment: .leading, spacing: 14) {
                heading
                if let hot = usage.limits.first(where: { $0.percent(at: now) >= 81 }) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(hot.name) is at \(Int(hot.percent(at: now).rounded()))%. A lighter model can stretch what's left.")
                        if !accounts.hasSeveral, let openAccounts {
                            // The moment someone wants a second account is
                            // when they run low on the first.
                            Button("Have another Claude account? Use it for some projects.", action: openAccounts)
                                .buttonStyle(.link)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(UsageColor.color(for: 100))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(UsageColor.color(for: 100).opacity(0.12)))
                }
                ForEach(usage.limits) { limit in
                    row(limit, now: now)
                }
                Divider()
                Text(footer(now: now))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Usage and Costs", action: openUsage)
                    .help("Tokens you've used and what they'd cost at API prices (⇧⌘U)")
            }
        }
    }

    private func row(_ limit: PlanLimit, now: Date) -> some View {
        let percent = limit.percent(at: now)
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(limit.name)
                if limit.isPerModel {
                    Text("per model").foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(Int(percent.rounded()))%")
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(UsageColor.color(for: percent))
            }
            .font(.callout)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.1))
                    Capsule().fill(UsageColor.color(for: percent))
                        .frame(width: proxy.size.width * percent / 100)
                    if showsPace, let elapsed = limit.elapsed(at: now) {
                        Capsule().fill(.primary.opacity(0.85))
                            .frame(width: 2, height: 11)
                            .offset(x: proxy.size.width * elapsed - 1)
                    }
                }
            }
            .frame(height: 7)
            Text(resetText(limit, now: now))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func resetText(_ limit: PlanLimit, now: Date) -> String {
        guard let reset = limit.resetsAt, reset > now, let left = limit.timeLeft(at: now) else {
            return "Reset. New numbers come in after your next message."
        }
        let sameDay = Calendar.current.isDate(reset, inSameDayAs: now)
        let clock = reset.formatted(sameDay ? .dateTime.hour().minute() : .dateTime.weekday(.wide).hour().minute())
        return "Resets in \(left), \(clock)"
    }

    private func footer(now: Date) -> String {
        let age = now.timeIntervalSince(usage.updated)
        let when = age < 90 ? "just now" : "\(PlanLimit.shortDuration(age)) ago"
        return "Updated \(when), from Claude Code and your Claude account. The tick on each bar shows how far into that window you are."
    }
}

/// For an API key or cloud account: this month's spending at API prices,
/// and how it's going against the budget, if there is one.
struct SpendDetails: View {
    let limit: PlanLimit
    let updated: Date
    let showsPace: Bool
    var accountID = ClaudeProfile.mainID
    let openUsage: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date
            let spent = limit.resetsAt.map { $0 <= now } == true ? 0 : limit.dollars ?? 0
            let percent = limit.percent(at: now)
            VStack(alignment: .leading, spacing: 14) {
                AccountHeading(title: "This month", accountID: accountID)
                if let budget = limit.budget, percent >= 81 {
                    Text(percent >= 100
                         ? "You've gone past this month's \(PlanLimit.dollarText(budget)) budget."
                         : "You've used \(Int(percent.rounded()))% of this month's budget. A lighter model costs less.")
                        .font(.callout)
                        .foregroundStyle(UsageColor.color(for: 100))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(UsageColor.color(for: 100).opacity(0.12)))
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(PlanLimit.dollarText(spent))
                            .font(.ui(size: 22, weight: .semibold).monospacedDigit())
                        if let budget = limit.budget {
                            Text("of \(PlanLimit.dollarText(budget))")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int(percent.rounded()))%")
                                .fontWeight(.semibold)
                                .monospacedDigit()
                                .foregroundStyle(UsageColor.color(for: percent))
                        }
                    }
                    if limit.budget != nil {
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.primary.opacity(0.1))
                                Capsule().fill(UsageColor.color(for: percent))
                                    .frame(width: proxy.size.width * percent / 100)
                                if showsPace, let elapsed = limit.elapsed(at: now) {
                                    Capsule().fill(.primary.opacity(0.85))
                                        .frame(width: 2, height: 11)
                                        .offset(x: proxy.size.width * elapsed - 1)
                                }
                            }
                        }
                        .frame(height: 7)
                    }
                    Text(resetText(now: now))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Divider()
                Text(footer(now: now))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(limit.budget == nil ? "Set a Budget" : "Usage and Costs", action: openUsage)
                    .help("What you've spent by day, model, and project (⇧⌘U)")
            }
        }
    }

    private func resetText(now: Date) -> String {
        guard let reset = limit.resetsAt, reset > now else { return "A new month has started." }
        return "Starts over \(reset.formatted(.dateTime.month(.wide).day()))"
    }

    private func footer(now: Date) -> String {
        let age = now.timeIntervalSince(updated)
        let when = age < 90 ? "just now" : "\(PlanLimit.shortDuration(age)) ago"
        let source = ClaudeAccounts.shared.account(for: accountID).status?.providerName ?? "an API key"
        var text = "This Claude account uses \(source), which bills by the token. This is this month's use at API prices, from Claude Code's logs. Updated \(when)."
        if limit.budget != nil, showsPace {
            text += " The tick shows how far into the month you are."
        }
        return text
    }
}

/// A card's heading, with whose account it is once there's more than one:
/// "Plan usage" over "Work · you@example.com".
struct AccountHeading: View {
    let title: String
    let accountID: UUID

    var body: some View {
        let accounts = ClaudeAccounts.shared
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
            if accounts.hasSeveral {
                let profile = accounts.profile(accountID)
                let email = accounts.account(for: accountID).status?.email
                Text([profile.name, email].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}
