import BenchKit
import Foundation

/// Your Claude plan's limits, for the rings at the bottom of the sidebar
/// and the phone.
///
/// The 5-hour and weekly numbers come from Claude Code itself: Bench's
/// status line step saves what Claude hands it after each reply
/// (`ClaudeProfile.statusFile`). Per-model limits, like Fable's weekly
/// one, aren't in there, so those come from your Claude account's usage
/// endpoint, using Claude Code's sign-in. That endpoint rate-limits
/// readily, so Bench asks every 10 minutes and backs off when told to.
///
/// There's one for each Claude account (`ClaudeAccounts`); `shared` is the
/// main account's.
@Observable
final class PlanUsageMonitor {
    static var shared: PlanUsageMonitor { ClaudeAccounts.shared.monitor(for: ClaudeProfile.mainID) }

    let profile: ClaudeProfile
    @ObservationIgnored private let account: ClaudeAccount

    static let shownKey = "planUsageShown"
    static let paceKey = "planUsagePace"
    /// A monthly budget in dollars for an API key or cloud account. 0 for none.
    static let budgetKey = "monthlyBudget"

    /// Nil until there's something to show: API key accounts never have
    /// plan limits.
    private(set) var usage: PlanUsage?

    @ObservationIgnored private var fromStatus: PlanUsage?
    @ObservationIgnored private var fromAccount: PlanUsage?
    @ObservationIgnored private var statusModified: Date?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var nextAccountCheck = Date.distantPast
    @ObservationIgnored private var lastAccountCheck = Date.distantPast
    @ObservationIgnored private var accountBackoff: TimeInterval = 0
    @ObservationIgnored private var checkingAccount = false
    /// For an account that pays per token: when the session logs were last
    /// read, and what the month's spending was built from last time.
    @ObservationIgnored private var ledgerRefreshed = Date.distantPast
    @ObservationIgnored private var spendInputs: SpendInputs?
    private static let ledgerInterval: TimeInterval = 5 * 60

    private struct SpendInputs: Equatable {
        var scanned: Date?
        var budget: Double
        var month: Date?
    }

    @ObservationIgnored private let accountFile: URL
    private static let accountInterval: TimeInterval = 600

    /// Where the agent's plan limits come from.
    @ObservationIgnored private let source: (any AgentPlanLimits)?

    init(profile: ClaudeProfile, account: ClaudeAccount, source: (any AgentPlanLimits)? = Agents.background(.claude).planLimits) {
        self.source = source
        self.profile = profile
        self.account = account
        accountFile = BenchPaths.support.appendingPathComponent(
            profile.isMain ? "plan-usage-account.json" : "plan-usage-account-\(profile.id.uuidString).json")
        if let data = try? Data(contentsOf: accountFile) {
            fromAccount = try? CompanionCoding.decoder.decode(PlanUsage.self, from: data)
        }
        readStatus()
        combine()
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    /// For an account taken off the list: the timer would otherwise fire
    /// for the rest of the process.
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Checks the account sooner, as when the details open, unless it was
    /// checked in the last couple of minutes or asked us to wait.
    func refreshSoon() {
        if account.paysPerToken || fallsBackToSpend { refreshSpendSoon() }
        if account.paysPerToken { return }
        guard accountBackoff == 0, Date().timeIntervalSince(lastAccountCheck) > 120 else { return }
        nextAccountCheck = .now
    }

    private func tick() {
        if account.paysPerToken {
            tickSpend()
            return
        }
        readStatus()
        if Date() >= nextAccountCheck, !checkingAccount { checkAccount() }
        if fallsBackToSpend {
            tickSpend()
            return
        }
        if spendInputs != nil {
            // Back on a plan: drop the spending meter for the plan's limits.
            spendInputs = nil
            usage = nil
            combine()
        }
    }

    /// True when Claude Code can't say how this account is billed and no
    /// plan limits have turned up, like a company gateway's token, or an
    /// Enterprise plan billed by usage. Plan limits take over if they appear.
    private var fallsBackToSpend: Bool {
        guard let status = account.status else { return false }
        let now = Date()
        let hasRecentLimits = [fromStatus, fromAccount].contains { usage in
            guard let usage, !usage.limits.isEmpty else { return false }
            return now.timeIntervalSince(usage.updated) < PlanLimit.week
        }
        return PlanUsage.showsSpendInstead(loggedIn: status.loggedIn, subscriptionType: status.subscriptionType,
                                           hasRecentLimits: hasRecentLimits)
    }

    /// Checks the account sooner, or reads the session logs again for an
    /// account that pays per token.
    private func refreshSpendSoon() {
        ledgerRefreshed = .distantPast
    }

    // MARK: Paying per token

    /// An API key or cloud account has no plan limits. What it has is a
    /// bill (see also `fallsBackToSpend`), so the meter is this month's spending at API prices, from the
    /// session logs, against the budget set in Settings if there is one.
    private func tickSpend() {
        let ledger = UsageLedger.shared
        if Date().timeIntervalSince(ledgerRefreshed) > Self.ledgerInterval {
            ledgerRefreshed = .now
            ledger.refresh()
        }
        let now = Date()
        let month = Calendar.current.dateInterval(of: .month, for: now)?.start
        let inputs = SpendInputs(scanned: ledger.lastScan, budget: Self.budget, month: month)
        guard inputs != spendInputs else { return }
        spendInputs = inputs
        let spent = month.map { ledger.cost(since: $0, in: profile) } ?? 0
        let next = PlanUsage(limits: [.monthSpend(dollars: spent, budget: Self.budget > 0 ? Self.budget : nil, now: now)],
                             updated: ledger.lastScan ?? now)
        if next != usage { usage = next }
    }

    static var budget: Double { max(UserDefaults.standard.double(forKey: budgetKey), 0) }

    // MARK: Claude Code's status line

    private func readStatus() {
        let file = profile.statusFile
        guard let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              modified != statusModified else { return }
        statusModified = modified
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = json["rate_limits"] as? [String: Any] else { return }
        let parsed = source?.limits(fromStatusLine: limits) ?? []
        guard !parsed.isEmpty else { return }
        fromStatus = PlanUsage(limits: parsed, updated: modified)
        combine()
    }

    // MARK: The account's usage endpoint

    private func checkAccount() {
        guard let source else { return }
        checkingAccount = true
        lastAccountCheck = .now
        Task {
            let result = await source.fetch(profile: profile)
            checkingAccount = false
            switch result {
            case .usage(let limits):
                accountBackoff = 0
                nextAccountCheck = Date().addingTimeInterval(Self.accountInterval)
                let usage = PlanUsage(limits: limits, updated: Date())
                fromAccount = usage
                do {
                    try CompanionCoding.encoder.encode(usage).write(to: self.accountFile, options: .atomic)
                } catch {
                    NSLog("Bench: couldn't save plan usage: \(error)")
                }
                combine()
            case .rateLimited(let retryAfter):
                accountBackoff = min(max(accountBackoff * 2, Self.accountInterval), 3600)
                nextAccountCheck = Date().addingTimeInterval(max(retryAfter ?? 0, accountBackoff))
            case .unavailable:
                nextAccountCheck = Date().addingTimeInterval(Self.accountInterval)
            }
        }
    }

    // MARK: Putting them together

    /// 5 hours, then the week, then per-model limits. For the first two,
    /// whichever source is newer wins.
    private func combine() {
        guard !account.paysPerToken else { return }
        var limits: [PlanLimit] = []
        for id in ["five_hour", "seven_day"] {
            let candidates = [fromStatus, fromAccount].compactMap { usage in
                usage.flatMap { u in u.limits.first { $0.id == id }.map { ($0, u.updated) } }
            }
            if let newest = candidates.max(by: { $0.1 < $1.1 }) { limits.append(newest.0) }
        }
        limits += fromAccount?.limits.filter(\.isPerModel) ?? []
        guard !limits.isEmpty else { return }
        let updated = [fromStatus?.updated, fromAccount?.updated].compactMap { $0 }.max() ?? Date()
        let next = PlanUsage(limits: limits, updated: updated)
        if next != usage { usage = next }
    }
}
