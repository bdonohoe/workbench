import SwiftUI

/// What a click on a turn's list of changes does, set where there's
/// somewhere to show them.
public struct TurnReviewActions {
    /// The project's folder, so files are named by their place in it.
    public var root: String?
    /// Shows what the turn did to one file.
    public var openFile: (TurnChanges, TurnChanges.File) -> Void
    /// Shows everything the turn changed, where that's possible.
    public var reviewAll: ((TurnChanges) -> Void)?

    public init(root: String?, openFile: @escaping (TurnChanges, TurnChanges.File) -> Void, reviewAll: ((TurnChanges) -> Void)? = nil) {
        self.root = root
        self.openFile = openFile
        self.reviewAll = reviewAll
    }
}

extension EnvironmentValues {
    /// Set to show each finished turn's changed files under it.
    @Entry public var turnReview: TurnReviewActions?
}

/// The files a finished turn changed, under its last row: each with how
/// many lines went in and came out, and a click away from its diff.
public struct TurnChangesCard: View {
    @Environment(\.companionPalette) private var palette
    @Environment(\.stepFonts) private var fonts
    @Environment(\.chatTurnStyle) private var style
    @Environment(\.turnReview) private var actions
    public let changes: TurnChanges
    @State private var showsAll = false

    /// Files shown before the rest fold away.
    static let foldsAfter = 6

    public init(changes: TurnChanges) {
        self.changes = changes
    }

    private var shown: [TurnChanges.File] {
        showsAll || changes.files.count <= Self.foldsAfter + 1 ? changes.files : Array(changes.files.prefix(Self.foldsAfter))
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 10, style: .continuous) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(palette.hairline).frame(height: 1)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(shown) { file in
                    TurnFileRow(changes: changes, file: file)
                }
                if shown.count < changes.files.count {
                    Button("Show all \(changes.files.count) files") {
                        withAnimation(.snappy(duration: 0.2)) { showsAll = true }
                    }
                    .buttonStyle(.pressable)
                    .font(fonts.text)
                    .foregroundStyle(StepColors.link)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                }
            }
            .padding(.vertical, 4)
            if let note = changes.incompleteNote {
                Text(note)
                    .font(fonts.caption)
                    .foregroundStyle(palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 9)
                    .padding(.top, 1)
            }
        }
        .background(palette.surface, in: shape)
        .overlay(shape.strokeBorder(palette.hairline))
        .padding(.leading, style.indent)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "plusminus")
                .font(.system(size: 11 * fonts.scale, weight: .semibold))
                .foregroundStyle(palette.ink.opacity(0.75))
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(Self.title(changes.files.count))
                .font(fonts.text.weight(.semibold))
                .foregroundStyle(palette.ink)
                .lineLimit(1)
            TurnCounts(additions: changes.additions, deletions: changes.deletions)
            Spacer(minLength: 8)
            if let reviewAll = actions?.reviewAll {
                Button("Review") { reviewAll(changes) }
                    .font(fonts.caption.weight(.semibold))
                    .buttonStyle(.pressable)
                    .foregroundStyle(palette.ink)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(palette.raised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .help("Read through everything this turn changed")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 9)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }

    /// "1 file changed in this turn", "3 files changed in this turn".
    static func title(_ count: Int) -> String {
        count == 1 ? "1 file changed in this turn" : "\(count) files changed in this turn"
    }
}

/// "+12 −3" in the chat's green and red.
private struct TurnCounts: View {
    @Environment(\.stepFonts) private var fonts
    let additions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: 5) {
            if additions > 0 { Text("+\(additions)").foregroundStyle(StepColors.added) }
            if deletions > 0 { Text("−\(deletions)").foregroundStyle(StepColors.removed) }
        }
        .font(fonts.monoSmall)
        .monospacedDigit()
        .lineLimit(1)
    }
}

/// One changed file: its name, where it is, and its counts. The whole
/// line takes the click.
private struct TurnFileRow: View {
    @Environment(\.companionPalette) private var palette
    @Environment(\.stepFonts) private var fonts
    @Environment(\.turnReview) private var actions
    let changes: TurnChanges
    let file: TurnChanges.File
    @State private var isHovering = false

    private var folder: String {
        let shown = TurnChanges.shownPath(file.path, root: actions?.root)
        return (shown as NSString).deletingLastPathComponent
    }

    var body: some View {
        Button {
            actions?.openFile(changes, file)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: file.isNewFile ? "doc.badge.plus" : "pencil")
                    .font(.system(size: 11 * fonts.scale, weight: .medium))
                    .foregroundStyle(palette.ink.opacity(0.75))
                    .frame(width: 14)
                    .accessibilityHidden(true)
                Text(file.fileName)
                    .font(fonts.mono)
                    .foregroundStyle(StepColors.link)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                Text(folder)
                    .font(fonts.caption)
                    .foregroundStyle(palette.inkMuted)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 8)
                if file.hasCounts {
                    TurnCounts(additions: file.additions, deletions: file.deletions)
                        .layoutPriority(2)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background {
                if isHovering {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(palette.ink.opacity(0.05))
                        .padding(.horizontal, 5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .disabled(actions == nil)
        .onHover { isHovering = $0 }
        .help("See what this turn changed in \(TurnChanges.shownPath(file.path, root: actions?.root))")
        .accessibilityLabel(label)
    }

    private var label: String {
        let what = file.isNewFile ? "Wrote" : "Edited"
        guard file.hasCounts else { return "\(what) \(file.fileName)" }
        return "\(what) \(file.fileName), \(file.additions) added, \(file.deletions) removed"
    }
}
