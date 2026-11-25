import Foundation
import SwiftUI

/// How long Claude has been working on your last message, or waiting on
/// you, ticking once a second. In the font of the line it sits in, with
/// digits of one width so the words beside it hold still.
public struct ActiveTimer: View {
    @Environment(\.companionPalette) private var palette
    public let since: Date
    public let activity: ActivityKind

    public init(since: Date, activity: ActivityKind) {
        self.since = since
        self.activity = activity
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Self.elapsed(context.date.timeIntervalSince(since)))
                .monospacedDigit()
                .fontWeight(.semibold)
                .foregroundStyle(palette.ink(for: activity))
                .fixedSize()
        }
    }

    /// "07s", "4m 09s", "1h 02m". Two-digit seconds and minutes keep the
    /// width steady from one tick to the next.
    public static func elapsed(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        if hours > 0 { return "\(hours)h " + String(format: "%02dm", minutes) }
        if minutes > 0 { return "\(minutes)m " + String(format: "%02ds", seconds) }
        return String(format: "%02ds", seconds)
    }

    /// The app's own darker takes on the activity colors, for a view with
    /// no palette in hand. Views with one use `CompanionPalette.ink(for:)`,
    /// which follows the terminal theme.
    public static func ink(for activity: ActivityKind) -> Color {
        CompanionPalette.system.ink(for: activity)
    }
}

extension CompanionProject {
    /// The session behind the project's activity that has been at it
    /// longest: when it started and what it's doing in words.
    public var activeSince: (since: Date, action: String?)? {
        sessions.filter { $0.activity == activity }
            .compactMap { session in session.since.map { (since: $0, action: session.action) } }
            .min { $0.since < $1.since }
    }
}
