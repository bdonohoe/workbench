import AppKit
import BenchKit
import Charts
import SwiftUI

/// What your Claude Code sessions on this Mac would cost at API prices, by
/// day, model, and project, next to your plan's limits.
struct UsageView: View {
    @Environment(AppStore.self) private var store
    @AppStorage("usage.days") private var days = 30
    @AppStorage("usage.showsTokens") private var showsTokens = false
    @State private var hoveredDay: Date?
    private var ledger: UsageLedger { .shared }

    var body: some View {
        let range = UsageRange(days: days, buckets: ledger.buckets)
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                accountCards
                if range.total.requests == 0 {
                    emptyState
                } else {
                    summary(range)
                    chart(range)
                    stats(range)
                    HStack(alignment: .top, spacing: 18) {
                        modelTable(range)
                        projectTable(range)
                    }
                    footnote
                }
            }
            .padding(28)
            .frame(maxWidth: 1080, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(TerminalTheme.shared.canvas)
        .navigationTitle("Usage")
        .task {
            // New sessions keep adding up while the page is open.
            while !Task.isCancelled {
                ledger.refresh()
                for profile in ClaudeAccounts.shared.profiles {
                    ClaudeAccounts.shared.monitor(for: profile.id).refreshSoon()
                    ClaudeAccounts.shared.account(for: profile.id).checkSoon()
                }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// Each Claude account's plan limits or spending. With one account the
    /// card says "Your Claude plan"; with more, each is named.
    @ViewBuilder private var accountCards: some View {
        let accounts = ClaudeAccounts.shared
        ForEach(accounts.profiles) { profile in
            let account = accounts.account(for: profile.id)
            let monitor = accounts.monitor(for: profile.id)
            let name = accounts.hasSeveral
                ? [profile.name, account.status?.email].compactMap { $0 }.joined(separator: " · ") : nil
            let spend = monitor.usage?.limits.first(where: \.isSpend)
            if account.paysPerToken || spend != nil {
                SpendCard(limit: spend, title: name ?? "This month")
            } else if let usage = monitor.usage {
                PlanCard(usage: usage, title: name ?? "Your Claude plan")
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Usage")
                .font(.ui(size: 22, weight: .semibold))
            if ledger.isScanning {
                ProgressView().controlSize(.small)
                Text(ledger.lastScan == nil ? "Reading your sessions…" : "Updating…")
                    .font(.ui(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Show", selection: $showsTokens) {
                Text("Cost").tag(false)
                Text("Tokens").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Picker("Range", selection: $days) {
                Text("7 days").tag(7)
                Text("30 days").tag(30)
                Text("90 days").tag(90)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    @ViewBuilder private var emptyState: some View {
        if ledger.lastScan == nil {
            ProgressView("Reading your Claude Code sessions…")
                .frame(maxWidth: .infinity, minHeight: 240)
        } else {
            ContentUnavailableView("No Claude Code usage yet", systemImage: "chart.bar",
                                   description: Text("Usage from Claude Code sessions on this Mac shows up here, from any app or terminal."))
                .frame(maxWidth: .infinity, minHeight: 240)
        }
    }

    // MARK: Headline

    private func summary(_ range: UsageRange) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(showsTokens ? UsageFormat.tokens(range.total.totalTokens) : UsageFormat.dollars(range.total.cost))
                .font(.ui(size: 40, weight: .semibold).monospacedDigit())
                .contentTransition(.numericText())
            Text(showsTokens
                 ? "tokens in \(range.label), \(UsageFormat.dollars(range.total.cost)) at API prices"
                 : "at Claude API prices in \(range.label)")
                .font(.ui(size: 13))
                .foregroundStyle(.secondary)
            if ClaudeAccount.shared.paysPerToken {
                let source = ClaudeAccount.shared.status?.providerName ?? "your API key"
                Text("Claude Code bills \(source) by the token, so this is close to what you paid.")
                    .font(.ui(size: 13, weight: .medium))
            } else if let usage = PlanUsageMonitor.shared.usage, !usage.limits.contains(where: \.isSpend) {
                Text("Your Claude plan covers this.")
                    .font(.ui(size: 13, weight: .medium))
                    .foregroundStyle(Color(nsColor: .systemGreen))
            }
        }
    }

    // MARK: Chart

    private func chart(_ range: UsageRange) -> some View {
        let families = range.families
        let hovered = hoveredDay.flatMap { day in range.daily.first { Calendar.current.isDate($0.date, inSameDayAs: day) } }
        return Chart {
            ForEach(range.daily) { day in
                ForEach(families, id: \.self) { family in
                    let tally = day.byFamily[family] ?? UsageTally()
                    BarMark(x: .value("Day", day.date, unit: .day),
                            y: .value(showsTokens ? "Tokens" : "Cost", showsTokens ? Double(tally.totalTokens) : tally.cost))
                        .foregroundStyle(by: .value("Model", family.name))
                        .opacity(hovered == nil || hovered?.date == day.date ? 1 : 0.45)
                }
            }
            if let hovered {
                RuleMark(x: .value("Day", hovered.date, unit: .day))
                    .foregroundStyle(Color.primary.opacity(0.12))
                    .zIndex(-1)
                    .annotation(position: .top, spacing: 6, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        DayTooltip(day: hovered, families: families, showsTokens: showsTokens)
                    }
            }
        }
        .chartForegroundStyleScale(domain: families.map(\.name), range: families.map(\.color))
        .chartLegend(position: .top, alignment: .leading, spacing: 12)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: range.days <= 7 ? 1 : range.days <= 30 ? 7 : 14)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.07))
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(showsTokens ? UsageFormat.tokens(Int(number)) : UsageFormat.dollars(number, cents: false))
                    }
                }
            }
        }
        .chartXSelection(value: $hoveredDay)
        .frame(height: 240)
        .padding(16)
        .background(panel)
    }

    // MARK: Stats

    private func stats(_ range: UsageRange) -> some View {
        let total = range.total
        let cachedShare = total.promptTokens == 0 ? 0 : Double(total.cacheRead) / Double(total.promptTokens)
        let savings = total.uncachedCost - total.cost
        return HStack(spacing: 12) {
            StatTile(title: "Tokens processed", value: UsageFormat.tokens(total.totalTokens),
                     detail: "\(total.requests.formatted()) requests")
            StatTile(title: "Read from cache", value: UsageFormat.tokens(total.cacheRead),
                     detail: "\(Int((cachedShare * 100).rounded()))% of input")
            StatTile(title: "New input", value: UsageFormat.tokens(total.input + total.cacheWrite),
                     detail: "\(UsageFormat.tokens(total.cacheWrite)) written to cache")
            StatTile(title: "Output", value: UsageFormat.tokens(total.output),
                     detail: "what Claude wrote")
            StatTile(title: "Saved by caching", value: UsageFormat.dollars(max(savings, 0)),
                     detail: total.cost > 0 ? String(format: "%.1f× cheaper than uncached", total.uncachedCost / total.cost) : " ")
        }
    }

    // MARK: Tables

    private func modelTable(_ range: UsageRange) -> some View {
        UsageTable(title: "By model", rows: range.byModel.map { model in
            UsageTable.Row(id: model.id, name: ContextUsage.modelName(model.id), color: ModelFamily(model: model.id).color,
                           tally: model.tally, share: range.share(model.tally), priced: ModelPrice.price(for: model.id) != nil)
        }, showsTokens: showsTokens)
    }

    private func projectTable(_ range: UsageRange) -> some View {
        var byName: [String: UsageTally] = [:]
        for (folder, tally) in range.byFolder { byName[projectName(for: folder), default: UsageTally()] += tally }
        let rows = byName.sorted { $0.value.cost > $1.value.cost }.map { name, tally in
            UsageTable.Row(id: name, name: name, color: nil, tally: tally, share: range.share(tally), priced: true)
        }
        return UsageTable(title: "By project", rows: rows, showsTokens: showsTokens, limit: 12)
    }

    /// The Workbench project a folder belongs to (agent worktrees count
    /// toward their project), or the folder's own name.
    private func projectName(for folder: String) -> String {
        let match = store.projects
            .filter { folder == $0.path || folder.hasPrefix($0.path + "/") }
            .max { $0.path.count < $1.path.count }
        if let match {
            return match.parentID.flatMap { store.project($0) }?.name ?? match.parentName ?? match.name
        }
        // Worktrees no longer in the sidebar still sit where Workbench puts them.
        if let repo = WorktreePaths.repoName(forFolder: folder, chosenFolder: Worktrees.chosenFolder?.path) {
            return repo
        }
        return folder.isEmpty ? "Unknown" : (folder as NSString).lastPathComponent
    }

    private var footnote: some View {
        Text("Estimated from the session logs Claude Code keeps on this Mac, at Anthropic's published API prices, including prompt caching. Sessions on other Macs, and anything else that uses the same key, aren't included. Claude Code deletes old logs after about a month; Workbench keeps daily totals from then on, so longer ranges fill in over time.")
            .font(.ui(size: 11))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var panel: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(UsagePanel.fill)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }
}

/// Panels match the sidebars when following the terminal theme.
enum UsagePanel {
    static var fill: Color { TerminalTheme.shared.panel ?? Color.primary.opacity(0.035) }
}

// MARK: - Model families

/// Models grouped for the chart, each with a color that stays the same
/// whatever else is on screen.
enum ModelFamily: Int, CaseIterable, Hashable {
    case fable, opus, sonnet, haiku, other

    init(model: String) {
        let id = model.lowercased()
        self = if id.contains("fable") || id.contains("mythos") { .fable }
            else if id.contains("opus") { .opus }
            else if id.contains("sonnet") { .sonnet }
            else if id.contains("haiku") { .haiku }
            else { .other }
    }

    var name: String {
        switch self {
        case .fable: "Fable"
        case .opus: "Opus"
        case .sonnet: "Sonnet"
        case .haiku: "Haiku"
        case .other: "Other"
        }
    }

    /// The terminal theme's own color for the family when matching it:
    /// blue, red, green, yellow, and magenta. Otherwise a set checked for
    /// color blindness, with its own steps in dark mode.
    var color: Color {
        let ansi: Int = switch self {
        case .fable: 4
        case .opus: 1
        case .sonnet: 2
        case .haiku: 3
        case .other: 5
        }
        return TerminalTheme.shared.ansiColor(ansi) ?? defaultColor
    }

    private var defaultColor: Color {
        switch self {
        case .fable: .dynamic(light: 0x2A78D6, dark: 0x3987E5)
        case .opus: .dynamic(light: 0xEB6834, dark: 0xD95926)
        case .sonnet: .dynamic(light: 0x1BAF7A, dark: 0x199E70)
        case .haiku: .dynamic(light: 0xEDA100, dark: 0xC98500)
        case .other: .dynamic(light: 0xE87BA4, dark: 0xD55181)
        }
    }
}

private extension Color {
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        func color(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? color(dark) : color(light)
        })
    }
}

// MARK: - The numbers for a range

private struct UsageRange {
    struct Day: Identifiable {
        var date: Date
        var byFamily: [ModelFamily: UsageTally]
        var id: Date { date }
        var total: UsageTally { byFamily.values.reduce(UsageTally(), +) }
    }

    let days: Int
    var daily: [Day] = []
    var total = UsageTally()
    var byModel: [(id: String, tally: UsageTally)] = []
    var byFolder: [String: UsageTally] = [:]
    var families: [ModelFamily] = []

    init(days: Int, buckets: [UsageBucket: UsageTally]) {
        self.days = days
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        var dayIndex: [String: Date] = [:]
        for offset in (0..<days).reversed() {
            let date = calendar.date(byAdding: .day, value: -offset, to: today)!
            dayIndex[formatter.string(from: date)] = date
        }
        var byDay: [Date: [ModelFamily: UsageTally]] = [:]
        var models: [String: UsageTally] = [:]
        var seenFamilies = Set<ModelFamily>()
        for (bucket, tally) in buckets {
            guard let date = dayIndex[bucket.day] else { continue }
            let family = ModelFamily(model: bucket.model)
            byDay[date, default: [:]][family, default: UsageTally()] += tally
            models[bucket.model, default: UsageTally()] += tally
            byFolder[bucket.folder, default: UsageTally()] += tally
            total += tally
            seenFamilies.insert(family)
        }
        daily = dayIndex.values.sorted().map { Day(date: $0, byFamily: byDay[$0] ?? [:]) }
        byModel = models.sorted { ($0.value.cost, $0.value.totalTokens) > ($1.value.cost, $1.value.totalTokens) }.map { ($0.key, $0.value) }
        families = ModelFamily.allCases.filter(seenFamilies.contains)
    }

    var label: String { "the last \(days) days" }

    func share(_ tally: UsageTally) -> Double {
        total.cost > 0 ? tally.cost / total.cost : (total.totalTokens > 0 ? Double(tally.totalTokens) / Double(total.totalTokens) : 0)
    }
}

// MARK: - Pieces

enum UsageFormat {
    static func dollars(_ value: Double, cents: Bool = true) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = cents && value < 100 ? 2 : 0
        formatter.minimumFractionDigits = formatter.maximumFractionDigits
        return formatter.string(from: NSNumber(value: value)) ?? "$\(Int(value))"
    }

    /// "8.4B", "270K", "40.0M".
    static func tokens(_ value: Int) -> String {
        let number = Double(value)
        return switch number {
        case ..<1000: "\(value)"
        case ..<1_000_000: String(format: "%.0fK", number / 1000)
        case ..<1_000_000_000: String(format: number < 10_000_000 ? "%.1fM" : "%.0fM", number / 1_000_000)
        default: String(format: "%.1fB", number / 1_000_000_000)
        }
    }
}

private struct DayTooltip: View {
    let day: UsageRange.Day
    let families: [ModelFamily]
    let showsTokens: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(day.date, format: .dateTime.weekday(.wide).month().day())
                .font(.ui(size: 11, weight: .semibold))
            ForEach(families.reversed(), id: \.self) { family in
                if let tally = day.byFamily[family], tally.requests > 0 {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(family.color).frame(width: 8, height: 8)
                        Text(family.name)
                        Spacer(minLength: 12)
                        Text(value(tally)).monospacedDigit()
                    }
                }
            }
            Divider()
            HStack {
                Text("Total")
                Spacer(minLength: 12)
                Text(value(day.total)).monospacedDigit()
            }
            .fontWeight(.semibold)
        }
        .font(.ui(size: 11))
        .padding(10)
        .frame(width: 180)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
    }

    private func value(_ tally: UsageTally) -> String {
        showsTokens ? UsageFormat.tokens(tally.totalTokens) : UsageFormat.dollars(tally.cost)
    }
}

private struct StatTile: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.ui(size: 11))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.ui(size: 19, weight: .semibold).monospacedDigit())
            Text(detail)
                .font(.ui(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(UsagePanel.fill))
    }
}

private struct UsageTable: View {
    struct Row: Identifiable {
        var id: String
        var name: String
        var color: Color?
        var tally: UsageTally
        var share: Double
        var priced: Bool
    }

    let title: String
    let rows: [Row]
    let showsTokens: Bool
    var limit = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.ui(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
            ForEach(rows.prefix(limit)) { row in
                HStack(spacing: 8) {
                    if let color = row.color {
                        RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
                    }
                    Text(row.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(UsageFormat.tokens(row.tally.totalTokens))
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .trailing)
                    Text(row.share > 0 && row.share < 0.005 ? "<1%" : "\(Int((row.share * 100).rounded()))%")
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                    Text(row.priced ? UsageFormat.dollars(row.tally.cost) : "–")
                        .frame(width: 76, alignment: .trailing)
                        .help(row.priced ? "" : "No API price known for this model")
                }
                .font(.ui(size: 12).monospacedDigit())
                .padding(.vertical, 6)
                if row.id != rows.prefix(limit).last?.id { Divider().opacity(0.5) }
            }
            if rows.count > limit {
                Text("and \(rows.count - limit) more")
                    .font(.ui(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 6)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(UsagePanel.fill))
    }
}

/// Your plan's limits as bars, like the sidebar rings opened up.
private struct PlanCard: View {
    let usage: PlanUsage
    var title = "Your Claude plan"

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.ui(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(usage.limits) { limit in
                    let percent = limit.percent(at: context.date)
                    HStack(spacing: 10) {
                        Text(limit.name)
                            .frame(width: 90, alignment: .leading)
                        ProgressView(value: percent, total: 100)
                            .tint(UsageColor.color(for: percent))
                        Text("\(Int(percent.rounded()))%")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                        Text(limit.timeLeft(at: context.date).map { "resets in \($0)" } ?? "")
                            .foregroundStyle(.secondary)
                            .frame(width: 110, alignment: .trailing)
                    }
                    .font(.ui(size: 12))
                }
            }
            .padding(14)
            .frame(maxWidth: 560, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(UsagePanel.fill))
        }
    }
}

/// For an account billed by the token: this month's spending so far, and a
/// monthly budget to measure it against. The budget drives the Month ring
/// in the sidebar and on the phone.
private struct SpendCard: View {
    let limit: PlanLimit?
    var title = "This month"
    @AppStorage(PlanUsageMonitor.budgetKey) private var budget = 0.0
    @State private var draft = ""
    @FocusState private var editing: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date
            let spent = limit.flatMap { $0.resetsAt.map { $0 <= now } == true ? 0 : $0.dollars } ?? 0
            let percent = budget > 0 ? min(spent / budget * 100, 100) : 0
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.ui(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(PlanLimit.dollarText(spent))
                        .font(.ui(size: 20, weight: .semibold).monospacedDigit())
                    Text(budget > 0 ? "of \(PlanLimit.dollarText(budget)) budget" : "so far at API prices")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if budget > 0 {
                        Text("\(Int(percent.rounded()))%")
                            .fontWeight(.semibold)
                            .monospacedDigit()
                            .foregroundStyle(UsageColor.color(for: percent))
                    }
                }
                .font(.ui(size: 12))
                if budget > 0 {
                    ProgressView(value: percent, total: 100)
                        .tint(UsageColor.color(for: percent))
                }
                HStack(spacing: 8) {
                    Text("Monthly budget")
                    TextField("None", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .multilineTextAlignment(.trailing)
                        .focused($editing)
                        .onSubmit(save)
                        .accessibilityLabel("Monthly budget in dollars")
                    Text("USD").foregroundStyle(.secondary)
                    Spacer()
                    if let reset = limit?.resetsAt, reset > now {
                        Text("Starts over \(reset.formatted(.dateTime.month(.wide).day()))")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.ui(size: 12))
                Text("Set what you'd like to stay under each month, like your API key's spend limit or your company's quota. The Month ring in the sidebar fills toward it. Leave it empty for no budget.")
                    .font(.ui(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: 560, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(UsagePanel.fill))
        }
        .onAppear { draft = Self.text(budget) }
        .onChange(of: editing) { _, now in if !now { save() } }
    }

    /// Takes "$1,000", "1000", or "" (no budget).
    private func save() {
        let digits = draft.filter { $0.isNumber || $0 == "." }
        budget = max(Double(digits) ?? 0, 0)
        draft = Self.text(budget)
    }

    private static func text(_ budget: Double) -> String {
        budget > 0 ? PlanLimit.dollarText(budget) : ""
    }
}

#if DEBUG
extension UsageView {
    /// Lays the page out in a hidden window and saves it as usage-light.png
    /// and usage-dark.png, so it can be checked without a screen.
    static func renderForTesting(to folder: URL) {
        _ = NSApplication.shared
        UsageLedger.shared.loadNow()
        var looks: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]
        if ProcessInfo.processInfo.environment["BENCH_RENDER_THEME"] != nil {
            // Catppuccin Mocha.
            func hex(_ value: UInt32) -> NSColor {
                NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                        blue: CGFloat(value & 0xFF) / 255, alpha: 1)
            }
            let ansi: [UInt32] = [0x45475A, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xBAC2DE,
                                  0x585B70, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xA6ADC8]
            TerminalTheme.shared.setForTesting(background: hex(0x1E1E2E), foreground: hex(0xCDD6F4), ansi: ansi.map(hex))
            looks = [("themed", .darkAqua)]
        }
        for (name, appearance) in looks {
            let host = NSHostingView(rootView: UsageView()
                .environment(AppStore())
                .frame(width: 1180, height: 1100))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 1100),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("usage-\(name).png"))
        }
    }
}
#endif
