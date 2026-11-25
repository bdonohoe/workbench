#if os(macOS)
import AppKit
#endif
import SwiftUI

/// The small status mark from Bench's sidebar: Claude's cycling symbols
/// while working, a breathing dot while waiting, a check when done.
public struct ActivityMark: View {
    @Environment(\.companionPalette) private var palette
    public let activity: ActivityKind
    public var size: CGFloat = 14
    @Environment(\.motionLevel) private var motionLevel
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    /// The iPhone app has no Motion setting, so the system's is checked too.
    private var reduceMotion: Bool { systemReduceMotion || motionLevel == .still }

    public init(activity: ActivityKind, size: CGFloat = 14) {
        self.activity = activity
        self.size = size
    }

    private static let frames = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"].map { $0 + "\u{FE0E}" }

    public var body: some View {
        Group {
            switch activity {
            case .working, .remoteWorking:
                let color = palette.color(for: activity) ?? .secondary
                if reduceMotion {
                    glyph(Self.frames[4], color: color)
                } else {
                    #if os(macOS)
                    // Played by the window server: a SwiftUI timeline here
                    // laid the whole window out again on every tick.
                    LayerMotion(kind: .glyphs(NSColor(color), size: size))
                        .frame(width: size, height: size)
                        .allowsHitTesting(false)
                    #else
                    TimelineView(.periodic(from: .now, by: 0.2)) { context in
                        let step = Int(context.date.timeIntervalSinceReferenceDate / 0.2)
                        glyph(Self.frames[step % Self.frames.count], color: color)
                    }
                    #endif
                }
            case .waiting:
                if reduceMotion {
                    Circle().fill(palette.waiting).frame(width: size * 0.7, height: size * 0.7)
                } else {
                    #if os(macOS)
                    LayerMotion(kind: .pulse(NSColor(palette.waiting), dot: size * 0.7, ring: size * 0.7, ringTo: size * 1.4,
                                             opacity: 0.35, opacityTo: 0, period: 1.4))
                        .frame(width: size, height: size)
                        .allowsHitTesting(false)
                    #else
                    TimelineView(.animation) { context in
                        let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                        let pulse = 0.5 - 0.5 * cos(phase * 2 * .pi)
                        Circle()
                            .fill(palette.waiting)
                            .frame(width: size * 0.7, height: size * 0.7)
                            .background(
                                Circle()
                                    .fill(palette.waiting.opacity(0.35 * (1 - pulse)))
                                    .frame(width: size * 0.7 * (1 + pulse), height: size * 0.7 * (1 + pulse))
                            )
                    }
                    #endif
                }
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: size * 1.1, weight: .semibold))
                    .foregroundStyle(palette.done)
            case .attention:
                Circle().fill(palette.attention).frame(width: size * 0.7, height: size * 0.7)
            case .idle:
                EmptyView()
            }
        }
        .frame(width: size, height: size)
    }

    private func glyph(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: size * 1.15, weight: .semibold))
            .foregroundStyle(color)
            .fixedSize()
            .frame(width: size, height: size)
    }
}

/// A project's icon as its Mac sent it, or a tile with its initial.
public struct CompanionProjectIcon: View {
    public let project: CompanionProject
    public let icon: Data?
    public let size: CGFloat
    /// A hairline edge, which helps small icons on a dark sidebar.
    public var outlined: Bool

    public init(project: CompanionProject, icon: Data?, size: CGFloat, outlined: Bool = true) {
        self.project = project
        self.icon = icon
        self.size = size
        self.outlined = outlined
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
        Group {
            if let icon, let image = ImageCache.shared.icon(icon, for: project.id) {
                Image(platformImage: image).resizable().interpolation(.high).scaledToFill()
            } else {
                let hue = IconTint.tileHue(for: project.repoName)
                LinearGradient(
                    colors: [
                        Color(hue: hue, saturation: 0.5, brightness: 0.85),
                        Color(hue: (hue + 0.04).truncatingRemainder(dividingBy: 1), saturation: 0.65, brightness: 0.6),
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                .overlay {
                    Text(project.repoName.prefix(1).uppercased())
                        .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(outlined ? 0.1 : 0), lineWidth: 0.5))
    }
}
