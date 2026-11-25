import SwiftUI

/// A command you ran from the chat with a leading `!`: the command as you
/// typed it, Running until it has run, then what it printed. All of it,
/// since you ran it to see the output: Claude's own command cards show
/// only the end, but a listing cut to its last two lines reads as a
/// listing of two things. Past a ceiling, the first lines and a button
/// for the rest, so a runaway command can't take over the conversation.
/// Drawn like Claude's command cards otherwise, with the `!` saying it
/// was you.
struct ShellRunCard: View {
    @Environment(\.companionPalette) private var palette
    @Environment(\.stepFonts) private var fonts
    let run: ShellRun
    @State private var showsAll = false

    /// Lines shown before the rest is behind a button.
    static let ceiling = 100

    private var lines: [String] {
        let output = run.output
        return output.isEmpty ? [] : output.components(separatedBy: "\n")
    }

    private var isCut: Bool { lines.count > Self.ceiling && !showsAll }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if lines.count > Self.ceiling { withAnimation(.snappy(duration: 0.2)) { showsAll.toggle() } }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .font(.system(size: 11.5 * fonts.scale))
                        .foregroundStyle(palette.inkMuted)
                    Text(run.typed)
                        .font(fonts.mono)
                        .foregroundStyle(palette.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    status
                }
                .font(fonts.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .help("You ran this in the project's shell. The agent sees what it printed.")
            if !lines.isEmpty {
                let shown = isCut ? Array(lines.prefix(Self.ceiling)) : lines
                VStack(alignment: .leading, spacing: 6) {
                    Text(shown.joined(separator: "\n"))
                        .font(fonts.monoSmall)
                        .foregroundStyle(run.looksFailed ? StepColors.removed : palette.inkMuted)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                    if isCut {
                        Button("Show all \(lines.count) lines") {
                            withAnimation(.snappy(duration: 0.2)) { showsAll = true }
                        }
                        .buttonStyle(.pressable)
                        .font(fonts.text.weight(.medium))
                        .foregroundStyle(StepColors.link)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .overlay(alignment: .top) { Rectangle().fill(palette.hairline).frame(height: 1) }
            }
        }
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(palette.hairline))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("You ran \(run.command)")
    }

    @ViewBuilder private var status: some View {
        if !run.isFinished {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Running").foregroundStyle(palette.inkMuted)
            }
        } else if lines.isEmpty {
            Text("Printed nothing").foregroundStyle(palette.inkMuted)
        } else if lines.count > Self.ceiling {
            Text(showsAll ? "Show less" : "\(lines.count) lines").foregroundStyle(palette.inkMuted)
        }
    }
}

/// A slash command you ran that prints something, like `/context`: the
/// command as you typed it, then what Claude Code printed for it, which
/// it otherwise shows only in its terminal. Drawn like a command you ran
/// with `!`. Tables and headings read as such when Claude Code recorded
/// Markdown; anything else keeps the spacing it was printed with.
struct CommandRunCard: View {
    @Environment(\.companionPalette) private var palette
    @Environment(\.stepFonts) private var fonts
    let run: CommandRun
    @State private var showsAll = false

    /// Lines of plain output shown before the rest is behind a button.
    static let ceiling = 60

    /// How tall Markdown output gets before the rest is behind a button.
    static let foldedHeight: CGFloat = 300
    /// The Markdown's full height, once it has been laid out.
    @State private var markdownHeight: CGFloat = 0

    private var lines: [String] { (run.output ?? "").components(separatedBy: "\n") }
    private var isCut: Bool { !run.isMarkdown && lines.count > Self.ceiling && !showsAll }
    /// Markdown with enough below the fold to be worth folding.
    private var folds: Bool { run.isMarkdown && markdownHeight > Self.foldedHeight + 80 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "command")
                    .font(.system(size: 11.5 * fonts.scale))
                    .foregroundStyle(palette.inkMuted)
                Text(run.typed)
                    .font(fonts.mono)
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .help("You ran this command. It was answered directly, without asking the agent.")
            VStack(alignment: .leading, spacing: 6) {
                if run.isMarkdown {
                    MarkdownText(text: run.output ?? "")
                        .font(fonts.text)
                        .foregroundStyle(palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { markdownHeight = $0 }
                        .frame(height: folds && !showsAll ? Self.foldedHeight : nil, alignment: .top)
                        .clipped()
                    if folds {
                        Button(showsAll ? "Show less" : "Show all of it") {
                            withAnimation(.snappy(duration: 0.2)) { showsAll.toggle() }
                        }
                        .buttonStyle(.pressable)
                        .font(fonts.text.weight(.medium))
                        .foregroundStyle(StepColors.link)
                    }
                } else {
                    Text((isCut ? Array(lines.prefix(Self.ceiling)) : lines).joined(separator: "\n"))
                        .font(fonts.monoSmall)
                        .foregroundStyle(palette.inkMuted)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                    if isCut {
                        Button("Show all \(lines.count) lines") {
                            withAnimation(.snappy(duration: 0.2)) { showsAll = true }
                        }
                        .buttonStyle(.pressable)
                        .font(fonts.text.weight(.medium))
                        .foregroundStyle(StepColors.link)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, run.isMarkdown ? 10 : 7)
            .overlay(alignment: .top) { Rectangle().fill(palette.hairline).frame(height: 1) }
        }
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(palette.hairline))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("You ran \(run.typed)")
    }
}
