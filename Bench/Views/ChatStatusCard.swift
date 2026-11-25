import BenchKit
import SwiftUI

/// One line of `/status`: what it is, and its value.
struct ChatStatusRow: Identifiable, Equatable {
    var label: String
    var value: String
    var id: String { label }
}

/// The installed Claude Code's version, asked for once and kept.
@MainActor @Observable
final class ClaudeCodeVersion {
    static let shared = ClaudeCodeVersion()
    private(set) var version: String?
    @ObservationIgnored private var asked = false

    /// The version if it's known, and a look for it if it hasn't been asked for.
    func current() -> String? {
        if !asked {
            asked = true
            Task {
                version = await Task.detached(priority: .utility) { Self.read() }.value
            }
        }
        return version
    }

    /// "2.1.325" out of "2.1.325 (Claude Code)".
    nonisolated private static func read() -> String? {
        Tools.resolveIfNeeded()
        guard let claude = Tools.path("claude") else { return nil }
        return Tools.run(claude, ["--version"], environment: Tools.environment)?
            .split(whereSeparator: \.isWhitespace).first.map(String.init)
    }
}

/// What `/status` shows, above the message box: the session's model,
/// account and setup. Claude Code shows this in a dialog in its terminal;
/// Workbench already knows all of it. It isn't part of the conversation,
/// and closing it lets it go.
struct ChatStatusCard: View {
    @Environment(\.companionPalette) private var palette
    @Environment(\.dockCardStyle) private var style
    let rows: [ChatStatusRow]
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(palette.accent)
                Text("Status")
                    .font(style.title)
                    .foregroundStyle(palette.ink)
                Spacer(minLength: 8)
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(style.caption.weight(.bold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .foregroundStyle(palette.inkMuted)
                .keyboardShortcut(.cancelAction)
                .help("Close")
                .accessibilityLabel("Close status")
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(rows) { row in
                    GridRow {
                        Text(row.label)
                            .foregroundStyle(palette.inkMuted)
                            .gridColumnAlignment(.leading)
                        Text(row.value)
                            .foregroundStyle(palette.ink)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .font(style.body)
        }
        .padding(14)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: style.radius ?? 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: style.radius ?? 20, style: .continuous)
            .strokeBorder(palette.accent.opacity(0.45), lineWidth: style.borderWidth ?? 1.5))
        .accessibilityElement(children: .contain)
    }
}
