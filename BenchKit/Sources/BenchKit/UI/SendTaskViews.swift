import SwiftUI

/// Where a task's project icon goes when Claude couldn't pick a project:
/// a dashed square with a question mark, in the waiting color.
public struct UnassignedProjectIcon: View {
    let size: CGFloat
    let color: Color

    public init(size: CGFloat, color: Color) {
        self.size = size
        self.color = color
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .strokeBorder(color, style: StrokeStyle(lineWidth: max(1, size / 14), dash: [size / 7, size / 9]))
            .overlay(Image(systemName: "questionmark")
                .font(.system(size: size * 0.45, weight: .bold))
                .foregroundStyle(color))
            .frame(width: size, height: size)
            .accessibilityLabel("No project yet")
    }
}

/// The line under a task saying which words of your message it came from.
public struct TaskSourceLine: View {
    let source: String

    public init(source: String) {
        self.source = source
    }

    public var body: some View {
        if !source.isEmpty {
            Text("From “\(source)”")
                .foregroundStyle(.tertiary)
                .lineLimit(2)
        }
    }
}
