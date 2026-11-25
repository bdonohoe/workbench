import BenchKit
import SwiftUI

/// A full-row background that shows a project's state at a glance:
/// - working: a tint in the theme's working color with a light sweep and
///   twinkling sparkles, for work here or on another machine. Working is
///   never gray (see `workingColor`), so the tint can't be mistaken for the
///   selected row's gray wash.
/// - waiting: an amber glow that breathes, because Claude needs you
/// - done: a solid green tint. When work finishes it brightens once and a
///   band of light sweeps across it, brighter than white on an HDR display
///   (`FinishHighlight`)
/// - attention: a calm blue tint for a bell or notification
/// The sparkles and the breath only play at Full motion (Settings ›
/// Appearance › Motion). Calm, Still, and Reduce Motion keep the tints.
/// Anything that loops keeps the window server redrawing the window every
/// frame, which cost about a third of a core with a row working.
struct ActivityBackground: View {
    let activity: TabActivity
    var cornerRadius: CGFloat = 9
    /// A thin outline in the state's color, for a card that stands alone
    /// (the Overview's). Off in the sidebar, where the only outline is the
    /// selected row's ring.
    var showsOutline = true
    @Environment(\.motionLevel) private var motionLevel
    @State private var flash = 0.0
    /// How far the finish's band of light has crossed the row: 0 at the
    /// leading edge, 1 once it's past the trailing one.
    @State private var sweep = 1.0
    /// Counts the finishes, each of which plays the HDR highlight once.
    @State private var finishes = 0

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        ZStack {
            switch activity {
            case .working, .remoteWorking:
                shape.fill(Self.working.opacity(0.16))
                if motionLevel == .full {
                    LayerMotion(kind: .sparkles(NSColor(Self.working)), cornerRadius: cornerRadius)
                        .allowsHitTesting(false)
                }
                if showsOutline { shape.strokeBorder(Self.working.opacity(0.5), lineWidth: 1) }
            case .waiting:
                if motionLevel == .full {
                    LayerMotion(kind: .breathing(NSColor(Self.waiting)), cornerRadius: cornerRadius)
                        .allowsHitTesting(false)
                } else {
                    shape.fill(Self.waiting.opacity(0.2))
                }
                if showsOutline { shape.strokeBorder(Self.waiting.opacity(0.6), style: outline) }
            case .done:
                shape.fill(Self.done.opacity(0.16 + flash * 0.18))
                // One soft band of light crosses the row as work wraps up.
                // At rest it sits past the trailing edge, clipped away.
                GeometryReader { proxy in
                    let band = max(60, proxy.size.width * 0.5)
                    LinearGradient(colors: [Self.done.opacity(0), Self.done.opacity(0.42), Self.done.opacity(0)],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: band)
                        .offset(x: -band + (proxy.size.width + band) * sweep)
                }
                .clipShape(shape)
                .allowsHitTesting(false)
                FinishHighlight(plays: finishes, color: Self.done, cornerRadius: cornerRadius)
                    .allowsHitTesting(false)
                if showsOutline { shape.strokeBorder(Self.done.opacity(0.5 + flash * 0.4), style: outline) }
            case .attention:
                shape.fill(Self.attention.opacity(0.1))
                if showsOutline { shape.strokeBorder(Self.attention.opacity(0.35), style: outline) }
            case .idle:
                Color.clear
            }
        }
        // The same clock as the row resizing around it (SidebarMotion), so
        // the tint never lags behind the row's new height.
        .animation(SidebarMotion.rowChange, value: activity)
        .onChange(of: activity) { old, new in
            // A quick bright pulse and a sweep when work wraps up, then it settles.
            // It plays once, so only Still skips it.
            guard new == .done, old != .done, motionLevel != .still else { return }
            flash = 1
            sweep = 0
            finishes += 1
            withAnimation(.easeOut(duration: FinishHighlight.flashDuration)) { flash = 0 }
            withAnimation(.easeInOut(duration: FinishHighlight.sweepDuration)) { sweep = 1 }
        }
    }

    /// Claude at work, in the terminal theme's color (its accent, or its
    /// orange when the accent would pass for another state). Claude
    /// orange when the window isn't matching a theme.
    @MainActor static var working: Color { TerminalTheme.shared.working }
    static let claudeOrange = Color(red: 0.85, green: 0.47, blue: 0.34)
    static let attention = Color.blue   // bell or notification; a status, not the app accent
    static let remote = Color(red: 0.34, green: 0.55, blue: 0.82)    // sky blue
    private let outline = StrokeStyle(lineWidth: 1)
    static let waiting = Color(red: 0.95, green: 0.68, blue: 0.15)   // amber
    static let done = Color(red: 0.2, green: 0.75, blue: 0.4)
}
