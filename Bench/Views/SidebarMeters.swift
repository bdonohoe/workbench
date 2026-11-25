import BenchKit
import SwiftUI

/// This Mac and your Claude plan at the foot of the sidebar, as one row of
/// small rings: CPU and memory, a hairline, then each of the plan's limits.
/// Everything stays grey while it's fine and colors in as it gets used up.
/// Running simulators, when that's turned on, are a count after the rings
/// that's only there while some are running.
/// Resting the pointer swells the rings into gauges with the numbers, and
/// a click (or resting a little longer) opens one card with the details of
/// both, the same way a project row works.
struct SidebarMeters: View {
    @AppStorage(MacActivity.shownKey) private var showsMac = true
    @AppStorage(PlanUsageMonitor.shownKey) private var showsPlan = true
    @AppStorage(PlanUsageMonitor.paceKey) private var showsPace = true
    @AppStorage(SimulatorWatch.shownKey) private var showsSimulators = true
    @State private var isHovering = Self.forcedHover
    @State private var overCard = false
    @State private var showsCard = Self.forcedOpen
    @State private var attached = false
    @State private var watching = false
    @Environment(\.companionPalette) private var palette
    @Environment(AppStore.self) private var store

    private var activity: MacActivity { .shared }
    private var watch: SimulatorWatch { .shared }
    /// The selected project's Claude account, since that's the one its
    /// Claude tabs are using up.
    private var accountID: UUID {
        guard store.selectedRemote == nil, let id = store.selectedProjectID else { return ClaudeProfile.mainID }
        return store.claudeAccountID(for: id)
    }
    private var monitor: PlanUsageMonitor { ClaudeAccounts.shared.monitor(for: accountID) }

    /// BENCH_USAGE_OPEN=1 shows the hover state and BENCH_ACTIVITY_OPEN=1
    /// opens the card, for screenshots.
    private static var forcedHover: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["BENCH_USAGE_OPEN"] != nil
        #else
        return false
        #endif
    }

    private static var forcedOpen: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["BENCH_ACTIVITY_OPEN"] != nil
        #else
        return false
        #endif
    }

    var body: some View {
        let summary = showsMac ? activity.summary : nil
        let usage = showsPlan ? monitor.usage : nil
        let simulators = showsSimulators ? watch.simulators : []
        Group {
            if summary != nil || usage != nil || !simulators.isEmpty {
                strip(summary: summary, usage: usage, simulators: simulators)
            } else {
                Color.clear.frame(height: 0)
            }
        }
        .onAppear {
            setAttached(showsMac)
            setWatching(showsSimulators)
        }
        .onDisappear {
            setAttached(false)
            setWatching(false)
        }
        .onChange(of: showsMac) { _, on in setAttached(on) }
        .onChange(of: showsSimulators) { _, on in
            setWatching(on)
            watch.setCardOpen(showsCard && on)
        }
        .onChange(of: showsCard) { _, open in
            activity.setCardOpen(open && showsMac)
            watch.setCardOpen(open && showsSimulators)
        }
        .onAppear {
            if showsCard {
                activity.setCardOpen(showsMac)
                watch.setCardOpen(showsSimulators)
            }
        }
    }

    private func strip(summary: MacActivity.Summary?, usage: PlanUsage?, simulators: [Simulator]) -> some View {
        let expanded = isHovering || showsCard
        // Countdowns tick by the minute; a reset can come at any time.
        return TimelineView(.periodic(from: .now, by: 30)) { context in
            let groups = meterGroups(summary: summary, usage: usage, simulators: simulators, now: context.date)
            HStack(alignment: .top, spacing: expanded ? 8 : 14) {
                ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                    if index > 0 {
                        Rectangle()
                            .fill(palette.hairline)
                            .frame(width: 1, height: expanded ? 40 : 20)
                            .padding(.top, expanded ? 0 : 1)
                    }
                    ForEach(group) { meter in
                        meterView(meter, expanded: expanded)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
        }
        .padding(.vertical, expanded ? 10 : 8)
        .padding(.horizontal, 6)
        // Glass, floating over the end of the project list, frosted toward
        // the sidebar's color so the rings stay readable over rows.
        .benchGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous),
                    tint: Color(nsColor: .windowBackgroundColor).opacity(0.75), interactive: true)
        .contentShape(Rectangle())
        .onTapGesture {
            showsCard.toggle()
            if showsCard { monitor.refreshSoon() }
        }
        .onHover { over in
            isHovering = over
            hoverChanged()
        }
        .popover(isPresented: $showsCard, arrowEdge: .trailing) {
            MetersCard(summary: summary, usage: usage, showsSimulators: !simulators.isEmpty,
                       showsPace: showsPace, accountID: accountID,
                       openUsage: {
                           showsCard = false
                           store.showsUsage = true
                       },
                       openAccounts: {
                           showsCard = false
                           store.settingsSection = .accounts
                       })
            .onHover { overCard = $0; hoverChanged() }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .animation(.smooth(duration: 0.22), value: expanded)
        .animation(.easeOut(duration: 0.3), value: summary)
        .animation(.smooth(duration: 0.22), value: simulators.count)
        .help(help(summary: summary, usage: usage, simulators: simulators))
    }

    // MARK: Rings

    /// One ring's worth of facts, for either state.
    private struct Meter: Identifiable {
        var id: String
        var percent: Double
        var elapsed: Double?
        var color: Color
        /// Under the small ring: "CPU", "5h".
        var caption: String
        /// Under the gauge: "Memory", "This week".
        var name: String
        /// Under the name: "3.1 cores", "16.2 GB", "1h 12m".
        var detail: String
        var spoken: String
        /// In the middle of the gauge in place of the percentage.
        var center: String?
        /// Not a share of anything: a count in a filled circle, like how
        /// many simulators are running.
        var count: Int?
    }

    /// The Mac's meters, then the plan's, then the simulators, each group
    /// its own array so a hairline can sit between them.
    private func meterGroups(summary: MacActivity.Summary?, usage: PlanUsage?, simulators: [Simulator],
                             now: Date) -> [[Meter]] {
        let calm = palette.ink.opacity(0.35)
        var groups: [[Meter]] = []
        if let summary {
            let cores = Double(summary.cpu) / 100 * Double(summary.cores)
            let memory: String = switch summary.pressure {
            case .normal: MacActivity.gigabytes(summary.memoryUsed)
            case .warning: "Tight"
            case .critical: "High"
            }
            groups.append([
                Meter(id: "cpu", percent: Double(summary.cpu), color: MeterColor.cpu(summary, calm: calm),
                      caption: "CPU", name: "CPU", detail: String(format: "%.1f cores", cores),
                      spoken: "CPU \(summary.cpu) percent"),
                Meter(id: "memory", percent: Double(summary.memoryPercent), color: MeterColor.memory(summary, calm: calm),
                      caption: "Memory", name: "Memory", detail: memory,
                      spoken: "memory \(summary.pressure == .normal ? "\(summary.memoryPercent) percent" : "high")"),
            ])
        }
        if let usage {
            groups.append(usage.limits.map { limit in
                let percent = limit.percent(at: now)
                if limit.isSpend {
                    // Without a budget there's no share to fill: the ring
                    // stays grey and says how much instead.
                    let budget = limit.budget
                    let spent = PlanLimit.shortDollars(limit.resetsAt.map { $0 <= now } == true ? 0 : limit.dollars ?? 0)
                    return Meter(id: limit.id, percent: percent,
                                 elapsed: showsPace && budget != nil ? limit.elapsed(at: now) : nil,
                                 color: budget == nil ? calm : UsageColor.quiet(for: percent, calm: calm),
                                 caption: spent, name: "Month",
                                 detail: budget.map { "of " + PlanLimit.shortDollars($0) } ?? "so far",
                                 spoken: UsageRing.spokenValue(limit, now: now),
                                 center: budget == nil ? spent : nil)
                }
                let left = limit.timeLeft(at: now)
                return Meter(id: limit.id, percent: percent, elapsed: showsPace ? limit.elapsed(at: now) : nil,
                             color: UsageColor.quiet(for: percent, calm: calm),
                             caption: limit.shortName, name: limit.shortName,
                             detail: left.map { percent >= 100 ? "back in \($0)" : $0 } ?? " ",
                             spoken: UsageRing.spokenValue(limit, now: now))
            })
        }
        // Sorted oldest first, and the oldest sets the color.
        if let oldest = simulators.first {
            let now = SimulatorWatch.clock(now)
            let age = oldest.age(at: now)
            let running = oldest.runningFor(at: now)
            let noun = simulators.count == 1 ? "simulator" : "simulators"
            groups.append([
                Meter(id: "simulators", percent: 100, color: age.color,
                      caption: "Sims", name: simulators.count == 1 ? "Simulator" : "Simulators",
                      // How long the oldest has been on. Room here is tight.
                      detail: running,
                      spoken: "\(simulators.count) \(noun) running, \(age.spoken)",
                      count: simulators.count),
            ])
        }
        return groups
    }

    /// One meter in either state. At rest it's a small plain ring with its
    /// name in small type beneath. Under the pointer the same ring grows
    /// and gains the percentage inside, its name, and a line of context.
    /// It's one ring that grows, not two views swapped: swapped, a small
    /// ring faded out in one place while a large one faded in in another.
    private func meterView(_ meter: Meter, expanded: Bool) -> some View {
        VStack(spacing: 3) {
            if let count = meter.count {
                CountBadge(count: count, tint: meter.color, size: expanded ? 40 : 20,
                           label: meter.name, value: meter.spoken)
            } else {
                UsageRing(percent: meter.percent, elapsed: meter.elapsed, tint: meter.color,
                          size: expanded ? 40 : 20, lineWidth: expanded ? 4 : 3,
                          showsPercent: expanded, label: meter.name, value: meter.spoken, center: meter.center)
            }
            if expanded {
                Text(meter.name)
                    .font(.ui(size: 11, weight: .semibold))
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                    .padding(.top, 2)
                    .transition(.opacity)
                Text(meter.detail)
                    .font(.ui(size: 11).monospacedDigit())
                    .foregroundStyle(palette.inkMuted)
                    .lineLimit(1)
                    .transition(.opacity)
            } else {
                Text(meter.caption)
                    .font(.ui(size: Theme.TypeScale.micro, weight: .medium))
                    .foregroundStyle(palette.inkMuted)
                    .lineLimit(1)
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: expanded ? .infinity : nil)
        .accessibilityElement(children: .combine)
    }

    private func help(summary: MacActivity.Summary?, usage: PlanUsage?, simulators: [Simulator]) -> String {
        if let summary, summary.level != .normal { return MeterColor.headline(summary) }
        var parts: [String] = []
        if summary != nil { parts.append("how hard this Mac is working") }
        if usage != nil {
            parts.append(usage?.limits.contains(where: \.isSpend) == true
                         ? "what Claude Code has cost this month" : "your Claude plan's limits")
        }
        if !simulators.isEmpty { parts.append("the simulators that are running") }
        let text = parts.count > 2
            ? parts.dropLast().joined(separator: ", ") + ", and " + parts[parts.count - 1]
            : parts.joined(separator: ", and ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    // MARK: Hover

    /// Opens the card after the pointer rests, so it doesn't flash while
    /// passing by, and closes it shortly after the pointer leaves both, so
    /// there's time to move onto the card. The same as a project row.
    private func hoverChanged() {
        if isHovering {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                if isHovering { showsCard = true }
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if !isHovering && !overCard { showsCard = false }
            }
        }
    }

    /// Sampling runs only while the Mac's rings are on screen.
    private func setAttached(_ on: Bool) {
        guard on != attached else { return }
        attached = on
        if on { activity.attach() } else { activity.detach() }
    }

    /// Looking for simulators runs only while it's turned on and the
    /// sidebar is on screen.
    private func setWatching(_ on: Bool) {
        guard on != watching else { return }
        watching = on
        if on { watch.attach() } else { watch.detach() }
    }
}

/// A count in a tinted circle, the size of the rings it sits beside. Filled
/// in, so it doesn't read as a share of something the way a ring does.
private struct CountBadge: View {
    let count: Int
    let tint: Color
    var size: CGFloat
    let label: String
    let value: String
    @Environment(\.companionPalette) private var palette

    var body: some View {
        ZStack {
            Circle().fill(tint.opacity(0.22))
            Circle()
                .inset(by: size * 0.05)
                .stroke(tint, lineWidth: size * 0.1)
            Text("\(count)")
                .font(.system(size: size * (count > 9 ? 0.4 : 0.5), weight: .bold).monospacedDigit())
                .foregroundStyle(palette.ink)
                .contentTransition(.numericText())
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}

/// One card for every part: what the Mac is doing and which projects are
/// responsible, the simulators that are running, then each plan limit with
/// its reset.
private struct MetersCard: View {
    let summary: MacActivity.Summary?
    let usage: PlanUsage?
    let showsSimulators: Bool
    let showsPace: Bool
    let accountID: UUID
    let openUsage: () -> Void
    let openAccounts: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if summary != nil {
                MacActivityCard()
            }
            if summary != nil, showsSimulators || usage != nil {
                Divider()
            }
            if showsSimulators {
                SimulatorsCard()
            }
            if showsSimulators, usage != nil {
                Divider()
            }
            if let usage {
                PlanUsageDetails(usage: usage, showsPace: showsPace, accountID: accountID,
                                 openUsage: openUsage, openAccounts: openAccounts)
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}
