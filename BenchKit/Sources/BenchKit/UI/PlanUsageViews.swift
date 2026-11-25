import SwiftUI

/// Green under half, yellow to 80%, orange from 81%, as most Claude
/// status lines color their limits.
public enum UsageColor {
    public static func color(for percent: Double) -> Color {
        percent >= 81 ? Color(red: 0.94, green: 0.54, blue: 0.24)
            : percent >= 50 ? Color(red: 0.90, green: 0.76, blue: 0.29)
            : Color(red: 0.37, green: 0.76, blue: 0.48)
    }

    /// The same scale, but `calm` grey until half used, so that in a quiet
    /// sidebar color always means "look here".
    public static func quiet(for percent: Double, calm: Color) -> Color {
        percent >= 50 ? color(for: percent) : calm
    }
}

/// One limit as a ring: the arc is how much is used, and the tick is how
/// far into the window you are. An arc past its tick is using the limit
/// up faster than the window runs out.
public struct UsageRing: View {
    let percent: Double
    /// How far through the window, 0 to 1, for the tick. Nil draws none.
    let elapsed: Double?
    /// Nil follows the usage scale: green, yellow, orange.
    let tint: Color?
    let label: String
    let value: String
    var size: CGFloat
    var lineWidth: CGFloat
    var showsPercent: Bool
    /// Shown in the middle in place of the percentage, like "$142".
    var center: String?
    @Environment(\.companionPalette) private var palette

    public init(limit: PlanLimit, now: Date, size: CGFloat, lineWidth: CGFloat, showsPercent: Bool, showsPace: Bool) {
        // Spending without a budget has no share to show: the ring stays
        // empty and the middle says how much.
        let unbudgeted = limit.isSpend && limit.budget == nil
        self.init(percent: limit.percent(at: now), elapsed: showsPace && !unbudgeted ? limit.elapsed(at: now) : nil, tint: nil,
                  size: size, lineWidth: lineWidth, showsPercent: showsPercent,
                  label: limit.name, value: Self.spokenValue(limit, now: now))
        if unbudgeted { center = limit.shortName }
    }

    /// A ring for any percentage, like CPU, with its own color and what
    /// VoiceOver reads for it.
    public init(percent: Double, elapsed: Double? = nil, tint: Color? = nil, size: CGFloat, lineWidth: CGFloat,
                showsPercent: Bool, label: String, value: String, center: String? = nil) {
        self.center = center
        self.percent = min(max(percent, 0), 100)
        self.elapsed = elapsed
        self.tint = tint
        self.size = size
        self.lineWidth = lineWidth
        self.showsPercent = showsPercent
        self.label = label
        self.value = value
    }

    public var body: some View {
        let radius = (size - lineWidth) / 2
        ZStack {
            Circle()
                .inset(by: lineWidth / 2)
                .stroke(palette.ink.opacity(0.1), lineWidth: lineWidth)
            Circle()
                .inset(by: lineWidth / 2)
                .trim(from: 0, to: max(percent / 100, 0.001))
                .stroke(tint ?? UsageColor.color(for: percent), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if let elapsed {
                Capsule()
                    .fill(palette.ink.opacity(0.9))
                    .frame(width: max(lineWidth / 3.5, 1.2), height: lineWidth + 2.5)
                    // Across the ring, poking out a little more on the outside.
                    .offset(y: -radius - 0.5)
                    .rotationEffect(.degrees(elapsed * 360))
            }
            if showsPercent, let center {
                Text(center)
                    .font(.system(size: size * 0.24, weight: .semibold).monospacedDigit())
                    .foregroundStyle(palette.ink)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding(.horizontal, lineWidth)
            } else if showsPercent {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("\(Int(percent.rounded()))")
                        .font(.system(size: size * 0.28, weight: .semibold).monospacedDigit())
                        .foregroundStyle(palette.ink)
                    Text("%")
                        .font(.system(size: size * 0.17, weight: .semibold))
                        .foregroundStyle(palette.inkMuted)
                }
            }
        }
        .frame(width: size, height: size)
        .animation(.smooth(duration: 0.35), value: percent)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }

    public static func spokenValue(_ limit: PlanLimit, now: Date) -> String {
        if let dollars = limit.dollars {
            let spent = PlanLimit.dollarText(dollars) + " spent this month"
            return limit.budget.map { spent + " of a " + PlanLimit.dollarText($0) + " budget" } ?? spent
        }
        var text = "\(Int(limit.percent(at: now).rounded())) percent used"
        if let left = limit.timeLeft(at: now) { text += ", resets in \(left)" }
        return text
    }
}

/// A ring with its percentage, name, and time until it resets.
public struct UsageGauge: View {
    let limit: PlanLimit
    let now: Date
    var size: CGFloat = 40
    var showsPace = true
    @Environment(\.companionPalette) private var palette

    public init(limit: PlanLimit, now: Date, size: CGFloat = 40, showsPace: Bool = true) {
        self.limit = limit
        self.now = now
        self.size = size
        self.showsPace = showsPace
    }

    public var body: some View {
        VStack(spacing: 3) {
            UsageRing(limit: limit, now: now, size: size, lineWidth: size * 0.1, showsPercent: true, showsPace: showsPace)
            Text(limit.isSpend ? "Month" : limit.shortName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.ink)
                .lineLimit(1)
                .padding(.top, 2)
            Text(timeLeft)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(palette.inkMuted)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var timeLeft: String {
        if limit.isSpend { return limit.budget.map { "of " + PlanLimit.shortDollars($0) } ?? "so far" }
        guard let left = limit.timeLeft(at: now) else { return " " }
        return limit.percent(at: now) >= 100 ? "back in \(left)" : left
    }
}

/// All of a plan's limits in a row: small plain rings, or full gauges.
public struct PlanUsageRow: View {
    let usage: PlanUsage
    var expanded: Bool
    var showsPace: Bool
    var gaugeSize: CGFloat

    public init(usage: PlanUsage, expanded: Bool, showsPace: Bool, gaugeSize: CGFloat = 40) {
        self.usage = usage
        self.expanded = expanded
        self.showsPace = showsPace
        self.gaugeSize = gaugeSize
    }

    public var body: some View {
        // Countdowns tick by the minute; a reset can come at any time.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if expanded {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(usage.limits) { limit in
                        UsageGauge(limit: limit, now: context.date, size: gaugeSize, showsPace: showsPace)
                    }
                }
            } else {
                HStack(spacing: 16) {
                    ForEach(usage.limits) { limit in
                        UsageRing(limit: limit, now: context.date, size: 20, lineWidth: 3, showsPercent: false, showsPace: showsPace)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}
