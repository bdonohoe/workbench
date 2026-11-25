import BenchKit
import SwiftUI

/// A small status mark: Claude's cycling symbols while an agent works, a pulsing
/// amber dot while it waits for your permission, a green checkmark when it
/// finished while you were away, and a blue dot for a bell or notification.
/// Shows nothing when idle.
struct ActivityIndicator: View {
    let activity: TabActivity
    var size: CGFloat = 9
    @Environment(\.motionLevel) private var motionLevel
    /// How many times work has finished while this mark was on screen.
    @State private var finishes = 0

    var body: some View {
        Group {
            switch activity {
            case .working:
                ClaudeGlyphSpinner(size: size, color: ActivityBackground.working)
                    .help("Working")
            case .remoteWorking:
                ClaudeGlyphSpinner(size: size, color: ActivityBackground.remote)
                    .help("Working on another machine")
            case .waiting:
                PulsingDot(color: ActivityBackground.waiting, size: size * 0.8)
                    .help("Waiting for you")
            case .done:
                DoneCheck(size: size * 1.3, drawToken: finishes)
                    .help("Finished. Check in on its changes.")
            case .attention:
                Circle().fill(ActivityBackground.attention)
                    .frame(width: size * 0.8, height: size * 0.8)
                    .help("Needs attention")
            case .idle:
                EmptyView()
            }
        }
        .frame(width: size, height: size)
        .transition(.scale.combined(with: .opacity))
        .animation(.spring(duration: 0.3), value: activity)
        .onChange(of: activity) { old, new in
            // Work wrapping up draws the check. A row that's already done
            // when it comes on screen just shows it.
            guard new == .done, old != .done, old != .idle, motionLevel != .still else { return }
            finishes += 1
        }
    }
}

/// The done mark: a green disc with a check cut out of it. When work has
/// just finished, the disc pops in and the check draws itself, stroke by
/// stroke. It plays once, so Calm shows it too, and only Still skips it.
private struct DoneCheck: View {
    let size: CGFloat
    /// Counts each finish. A change plays the drawing.
    let drawToken: Int

    private struct Frame {
        var disc = 1.0
        var check = 1.0
    }

    var body: some View {
        KeyframeAnimator(initialValue: Frame(), trigger: drawToken) { frame in
            ZStack {
                Circle().fill(ActivityBackground.done)
                CheckStroke()
                    .trim(from: 0, to: frame.check)
                    .stroke(style: StrokeStyle(lineWidth: size * 0.15, lineCap: .round, lineJoin: .round))
                    .blendMode(.destinationOut)
            }
            .compositingGroup()
            .scaleEffect(frame.disc)
            .frame(width: size, height: size)
        } keyframes: { _ in
            KeyframeTrack(\.disc) {
                MoveKeyframe(0.5)
                SpringKeyframe(1, duration: 0.35, spring: .snappy(duration: 0.3, extraBounce: 0.25))
            }
            KeyframeTrack(\.check) {
                MoveKeyframe(0)
                LinearKeyframe(0, duration: 0.2)
                CubicKeyframe(1, duration: 0.32)
            }
        }
        .accessibilityLabel("Finished")
    }
}

/// A check mark's two strokes, drawn from the short one's start.
nonisolated private struct CheckStroke: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.29, y: rect.minY + rect.height * 0.53))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.44, y: rect.minY + rect.height * 0.67))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.71, y: rect.minY + rect.height * 0.36))
        return path
    }
}

/// The symbols Claude Code cycles through in the terminal while it works.
struct ClaudeGlyphSpinner: View {
    let size: CGFloat
    let color: Color
    @Environment(\.motionLevel) private var motionLevel
    private var reduceMotion: Bool { motionLevel == .still }

    /// U+FE0E keeps each one a plain symbol, never an emoji.
    static let frames = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"].map { $0 + "\u{FE0E}" }

    var body: some View {
        if reduceMotion {
            glyph(Self.frames[4])
        } else {
            LayerMotion(kind: .glyphs(NSColor(color), size: size))
                .frame(width: size, height: size)
                .allowsHitTesting(false)
        }
    }

    private func glyph(_ text: String) -> some View {
        Text(text)
            .font(.system(size: size * 1.15, weight: .semibold))
            .foregroundStyle(color)
            .fixedSize()
            .frame(width: size, height: size)
    }
}

/// A dot that gently breathes, so a waiting agent stands out from a finished one.
private struct PulsingDot: View {
    let color: Color
    let size: CGFloat
    @Environment(\.motionLevel) private var motionLevel
    private var reduceMotion: Bool { motionLevel == .still }

    var body: some View {
        if reduceMotion {
            Circle().fill(color).frame(width: size, height: size)
        } else {
            LayerMotion(kind: .pulse(NSColor(color), dot: size, ring: size, ringTo: size * 2,
                                     opacity: 0.35, opacityTo: 0, period: 1.4))
                .frame(width: size, height: size)
                .allowsHitTesting(false)
        }
    }
}
