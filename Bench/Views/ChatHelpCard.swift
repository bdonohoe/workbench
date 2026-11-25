import BenchKit
import SwiftUI

/// What `/help` shows, above the message box: every command you can type
/// here, grouped by where it comes from. The list that appears as you
/// type a `/` only has room for the closest few. Click one to put it in
/// the message box.
struct ChatHelpCard: View {
    @Environment(\.companionPalette) private var palette
    @Environment(\.dockCardStyle) private var style
    let commands: [SlashCommand]
    let pick: (SlashCommand) -> Void
    let close: () -> Void
    @State private var contentHeight: CGFloat = 0

    /// A group of commands under one heading.
    struct Section: Identifiable, Equatable {
        var title: String
        var commands: [SlashCommand]
        var id: String { title }
    }

    /// The commands by where they come from: Claude Code's own first, then
    /// the project's, yours, and each plugin's, every group in name order.
    static func sections(_ commands: [SlashCommand]) -> [Section] {
        let sorted = commands.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var sections = [
            Section(title: "Claude Code", commands: sorted.filter { $0.source == .builtIn }),
            Section(title: "This project", commands: sorted.filter { $0.source == .project }),
            Section(title: "Yours", commands: sorted.filter { $0.source == .user }),
        ]
        let plugins = Dictionary(grouping: sorted.filter { $0.source == .plugin }) { command in
            command.name.split(separator: ":").first.map(String.init) ?? "Plugins"
        }
        sections += plugins.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { Section(title: $0, commands: plugins[$0] ?? []) }
        return sections.filter { !$0.commands.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(palette.accent)
                Text("Commands")
                    .font(style.title)
                    .foregroundStyle(palette.ink)
                Text("\(commands.count)")
                    .font(style.caption)
                    .foregroundStyle(palette.inkMuted)
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
                .accessibilityLabel("Close the command list")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Self.sections(commands)) { section in
                        Text(section.title)
                            .font(style.caption.weight(.semibold))
                            .foregroundStyle(palette.inkMuted)
                            .padding(.horizontal, 8)
                            .padding(.top, section.id == "Claude Code" ? 0 : 10)
                            .padding(.bottom, 3)
                        ForEach(section.commands) { command in
                            HelpRow(command: command) { pick(command) }
                        }
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(max(contentHeight, 1), 340))
            Text("Type / for commands, @ for a file, ! to run a shell command, and /btw to ask a side question.")
                .font(style.caption)
                .foregroundStyle(palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: style.radius ?? 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: style.radius ?? 20, style: .continuous)
            .strokeBorder(palette.accent.opacity(0.45), lineWidth: style.borderWidth ?? 1.5))
        .accessibilityElement(children: .contain)
    }
}

private struct HelpRow: View {
    @Environment(\.companionPalette) private var palette
    @Environment(\.dockCardStyle) private var style
    let command: SlashCommand
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("/" + command.name)
                    .font(.ui(size: Theme.TypeScale.bodySmall, weight: .semibold, design: .monospaced))
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let hint = command.argumentHint {
                    Text(hint)
                        .font(.ui(size: Theme.TypeScale.meta, design: .monospaced))
                        .foregroundStyle(palette.inkMuted.opacity(0.8))
                        .lineLimit(1)
                }
                Text(command.description)
                    .font(style.caption)
                    .foregroundStyle(palette.inkMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                if command.opensInTerminal {
                    Text("Terminal")
                        .font(.ui(size: Theme.TypeScale.meta, weight: .medium))
                        .foregroundStyle(palette.inkMuted)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(palette.ink.opacity(0.07), in: Capsule())
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4.5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(hovering ? palette.accent.opacity(0.16) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .onHover { hovering = $0 }
        .help(command.description)
    }
}
