import SwiftUI

/// "+12 −3" in green and red.
public struct LineCounts: View {
    @Environment(\.companionPalette) private var palette
    public let additions: Int
    public let deletions: Int

    public init(additions: Int, deletions: Int) {
        self.additions = additions
        self.deletions = deletions
    }

    public var body: some View {
        HStack(spacing: 6) {
            if additions > 0 { Text("+\(additions)").foregroundStyle(palette.done) }
            if deletions > 0 { Text("−\(deletions)").foregroundStyle(.red) }
        }
        .font(.caption.monospacedDigit())
    }
}

/// A stretch of unchanged lines left out of a diff, as one row that
/// opens it in place.
public struct DiffFoldRow: View {
    @Environment(\.companionPalette) private var palette
    public let text: String
    public var minWidth: CGFloat = 0
    public let action: () -> Void

    public init(text: String, minWidth: CGFloat = 0, action: @escaping () -> Void) {
        self.text = text
        self.minWidth = minWidth
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.and.down")
                    .font(.caption2.weight(.semibold))
                Text(text)
            }
            .foregroundStyle(palette.accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .fixedSize(horizontal: true, vertical: false)
            .frame(minWidth: minWidth, alignment: .leading)
            .background(Color.primary.opacity(0.05))
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
    }
}

/// One line of a diff: green and red lines, with the changed words marked.
/// Put it in a monospaced font and a scroll view that goes both ways.
public struct DiffLineRow: View {
    @Environment(\.companionPalette) private var palette
    public let line: DiffLine
    /// Lines stretch to at least this, so backgrounds reach the edge.
    public var minWidth: CGFloat = 0

    public init(line: DiffLine, minWidth: CGFloat = 0) {
        self.line = line
        self.minWidth = minWidth
    }

    public var body: some View {
        switch line.kind {
        case .hunk:
            // Inside a scroll view that goes both ways, a line has to say
            // how wide it is, or it gets squeezed into a column.
            Text(line.text.isEmpty ? "…" : line.text)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: minWidth, alignment: .leading)
                .background(Color.primary.opacity(0.05))
        case .meta:
            Text(line.text)
                .foregroundStyle(.secondary)
                .italic()
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: minWidth, alignment: .leading)
        case .context, .added, .removed:
            HStack(alignment: .top, spacing: 0) {
                Text(number(line.oldNumber))
                    .frame(width: 38, alignment: .trailing)
                Text(number(line.newNumber))
                    .frame(width: 38, alignment: .trailing)
                    .padding(.trailing, 8)
                Text(marker)
                    .frame(width: 10)
                content
                    .padding(.trailing, 16)
            }
            .padding(.vertical, 1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(minWidth: minWidth, alignment: .leading)
            .background(background)
        }
    }

    private var marker: String {
        switch line.kind {
        case .added: "+"
        case .removed: "−"
        default: " "
        }
    }

    private var background: Color {
        switch line.kind {
        case .added: palette.done.opacity(0.14)
        case .removed: Color.red.opacity(0.12)
        default: .clear
        }
    }

    @ViewBuilder
    private var content: some View {
        if let code = line.code, !code.isEmpty {
            // Colored code, with changed words marked by a tint behind them
            // rather than a color of their own.
            Text(codeText(line.text, runs: code).markingChanged(line.segments, tint: changeTint))
        } else if line.segments.isEmpty {
            Text(line.text.isEmpty ? " " : line.text)
        } else {
            line.segments.reduce(Text("")) { result, segment in
                result + (segment.changed
                    ? Text(segment.text).foregroundStyle(line.kind == .added ? palette.done : .red).bold()
                    : Text(segment.text))
            }
        }
    }

    private var changeTint: Color {
        line.kind == .added ? palette.done.opacity(0.3) : Color.red.opacity(0.25)
    }

    private func number(_ n: Int?) -> String {
        n.map(String.init) ?? ""
    }
}

extension AttributedString {
    /// Tints the changed words of a word-diffed line. `segments` spell
    /// out the whole line, so their lengths give each one's place.
    func markingChanged(_ segments: [DiffLine.Segment], tint: Color) -> AttributedString {
        guard segments.contains(where: \.changed) else { return self }
        var result = self
        var offset = 0
        for segment in segments {
            let length = segment.text.utf16.count
            if segment.changed, length > 0,
               let range = Range(NSRange(location: offset, length: length), in: result) {
                result[range].backgroundColor = tint
            }
            offset += length
        }
        return result
    }
}
