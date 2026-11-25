import ActivityKit
import BenchKit
import SwiftUI
import WidgetKit

@main
struct BenchWidgets: WidgetBundle {
    var body: some Widget {
        DashboardActivityWidget()
    }
}

/// Every session on a Mac, on the lock screen and in the Dynamic Island.
struct DashboardActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DashboardAttributes.self) { context in
            Roster(macName: context.attributes.macName, state: context.state, isStale: context.isStale)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.attributes.macName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Summary(state: state, isStale: context.isStale)
                        .padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 4) {
                        ForEach(state.rows.prefix(3)) { row in
                            RowView(row: row, showsText: false)
                        }
                        if state.rows.isEmpty { Nothing() }
                    }
                    .padding(.horizontal, 6)
                }
            } compactLeading: {
                if state.waiting > 0 {
                    Count(activity: "waiting", count: state.waiting)
                } else {
                    Count(activity: "working", count: state.working)
                }
            } compactTrailing: {
                if state.waiting > 0, state.working > 0 {
                    Count(activity: "working", count: state.working)
                } else if state.waiting == 0, state.done > 0 {
                    Count(activity: "done", count: state.done)
                }
            } minimal: {
                Glyph(activity: state.waiting > 0 ? "waiting" : state.working > 0 ? "working" : "done", size: 14)
            }
        }
    }
}

/// The lock screen view: a header, then one row per session.
private struct Roster: View {
    let macName: String
    let state: DashboardAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(macName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Summary(state: state, isStale: isStale)
            }
            if state.rows.isEmpty {
                Nothing()
            } else {
                ForEach(Array(state.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider().overlay(.white.opacity(0.12)) }
                    RowView(row: row, showsText: true)
                }
            }
        }
        .foregroundStyle(.white)
    }
}

/// "2 working · 1 needs you", or a warning when the Mac's gone quiet.
private struct Summary: View {
    let state: DashboardAttributes.ContentState
    let isStale: Bool

    var body: some View {
        Group {
            if isStale {
                Text("Mac not updating")
                    .foregroundStyle(.white.opacity(0.6))
            } else {
                let parts = parts
                if let first = parts.first {
                    parts.dropFirst().reduce(first) { $0 + Text(" · ").foregroundStyle(.white.opacity(0.6)) + $1 }
                }
            }
        }
        .font(.caption)
        .lineLimit(1)
    }

    private var parts: [Text] {
        var parts: [Text] = []
        if state.working > 0 { parts.append(Text("\(state.working) working").foregroundStyle(.white.opacity(0.6))) }
        if state.waiting > 0 { parts.append(Text("\(state.waiting) need\(state.waiting == 1 ? "s" : "") you").foregroundStyle(Palette.color(for: "waiting"))) }
        if parts.isEmpty, state.done > 0 { parts.append(Text("\(state.done) done").foregroundStyle(.white.opacity(0.6))) }
        if state.more > 0 { parts.append(Text("+\(state.more) more").foregroundStyle(.white.opacity(0.6))) }
        return parts
    }
}

private struct RowView: View {
    let row: DashboardRow
    /// False in the Dynamic Island, where there's room for less.
    let showsText: Bool

    private var needsYou: Bool { [.waiting, .attention].contains(row.kind) }

    var body: some View {
        HStack(spacing: 8) {
            Glyph(activity: row.activity, size: 15)
            HStack(spacing: 6) {
                Text(row.project)
                    .fontWeight(.semibold)
                    .layoutPriority(1)
                if showsText {
                    Text(row.text)
                        .foregroundStyle(needsYou ? Palette.color(for: "waiting") : .white.opacity(0.6))
                }
            }
            .lineLimit(1)
            Spacer(minLength: 4)
            trailing
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
        }
        .font(.footnote)
    }

    @ViewBuilder
    private var trailing: some View {
        if row.kind == .done {
            switch row.checks {
            case "passing": Text("PR ✓").foregroundStyle(Palette.color(for: "done"))
            case "failing": Text("PR ✗").foregroundStyle(.red)
            case "pending": Text("PR …")
            default: Text("Done")
            }
        } else if let since = row.since {
            Text(timerInterval: since...Date.distantFuture, countsDown: false)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 52, alignment: .trailing)
        }
    }
}

private struct Nothing: View {
    var body: some View {
        Text("Nothing running right now")
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.6))
    }
}

/// A state's glyph and how many sessions are in it, for the compact island.
private struct Count: View {
    let activity: String
    let count: Int

    var body: some View {
        HStack(spacing: 3) {
            Glyph(activity: activity, size: 13)
            Text("\(count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Palette.color(for: activity))
        }
    }
}

/// Claude's symbol for working, a raised hand for waiting, a check for done.
private struct Glyph: View {
    let activity: String
    let size: CGFloat

    var body: some View {
        let color = Palette.color(for: activity)
        switch activity {
        case "waiting", "attention":
            Image(systemName: "hand.raised.fill")
                .font(.system(size: size * 0.85, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: size, height: size)
        case "done":
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: size * 0.95, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: size, height: size)
        default:
            Text("✻\u{FE0E}")
                .font(.system(size: size * 1.05, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: size, height: size)
        }
    }
}

private enum Palette {
    static func color(for activity: String) -> Color {
        switch activity {
        case "working": Color(red: 0.85, green: 0.47, blue: 0.34)
        case "remoteWorking": Color(red: 0.42, green: 0.45, blue: 0.95)
        case "waiting", "attention": Color(red: 0.95, green: 0.68, blue: 0.15)
        case "done": Color(red: 0.2, green: 0.75, blue: 0.4)
        default: .secondary
        }
    }
}
