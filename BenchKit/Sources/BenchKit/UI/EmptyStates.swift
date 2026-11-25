import SwiftUI

/// The frame the bigger empty states share: a small terminal-style panel
/// that shows what will be here, a title, a line of copy, and an optional
/// button. Drawn in the companion palette, so it follows the terminal
/// theme on the Mac and the phone's theme there.
///
/// The illustration is a closure taking `appeared`, so each one runs its
/// own arrival off the same flag. Words between backticks in the message
/// are set as code, for keys and commands.
public struct EmptyStateScaffold<Illustration: View, Accessory: View>: View {
    public enum Size: Sendable {
        /// A whole pane.
        case regular
        /// A narrow side panel.
        case compact
    }

    @Environment(\.companionPalette) private var palette
    let title: String
    let message: String
    var size: Size
    var actionTitle: String?
    var action: (() -> Void)?
    let illustration: (Bool) -> Illustration
    let accessory: Accessory

    @State private var appeared = false

    public init(title: String, message: String, size: Size = .regular,
                actionTitle: String? = nil, action: (() -> Void)? = nil,
                @ViewBuilder illustration: @escaping (Bool) -> Illustration,
                @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.message = message
        self.size = size
        self.actionTitle = actionTitle
        self.action = action
        self.illustration = illustration
        self.accessory = accessory()
    }

    private var isCompact: Bool { size == .compact }
    private var illustrationHeight: CGFloat { isCompact ? 96 : 116 }

    private var titleFont: Font {
        #if os(macOS)
        .system(size: isCompact ? 14 : 17, weight: .semibold)
        #else
        isCompact ? .headline : .title3.weight(.semibold)
        #endif
    }

    private var messageFont: Font {
        #if os(macOS)
        .system(size: isCompact ? 12 : 13)
        #else
        isCompact ? .footnote : .subheadline
        #endif
    }

    public var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            illustration(appeared)
                .scaleEffect(isCompact ? 0.88 : 1)
                .frame(height: illustrationHeight)
                .accessibilityHidden(true)

            Text(title)
                .font(titleFont)
                .foregroundStyle(palette.ink)
                .multilineTextAlignment(.center)
                .padding(.top, isCompact ? 14 : 22)

            messageText
                .font(messageFont)
                .foregroundStyle(palette.inkMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                // No vertical fixedSize here. When the window works out its
                // smallest size it offers no width, the message wraps to a
                // letter a line, and a fixed height reports all of that as
                // the least it needs: the window's content came out taller
                // than the window, pushing the toolbar and message box off.
                .frame(maxWidth: isCompact ? 260 : 360)
                .padding(.top, isCompact ? 6 : 8)

            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.system(size: isCompact ? 12 : 13, weight: .semibold))
                        .foregroundStyle(palette.onAccent)
                        .padding(.horizontal, isCompact ? 14 : 18)
                        .frame(height: isCompact ? 26 : 30)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(palette.accent))
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(EmptyStatePress())
                .padding(.top, isCompact ? 16 : 22)
            }

            accessory

            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(appeared ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: appeared)
        .onAppear { appeared = true }
    }

    /// The message, with `backticked` words in the code font and color.
    private var messageText: Text {
        var text = Text("")
        for (index, piece) in message.split(separator: "`", omittingEmptySubsequences: false).enumerated() {
            let part = Text(String(piece))
            text = text + (index.isMultiple(of: 2) ? part : part.font(codeFont).foregroundColor(palette.code))
        }
        return text
    }

    private var codeFont: Font {
        #if os(macOS)
        .system(size: isCompact ? 11.5 : 12.5, weight: .medium, design: .monospaced)
        #else
        .system(isCompact ? .footnote : .subheadline, design: .monospaced).weight(.medium)
        #endif
    }
}

extension EmptyStateScaffold where Accessory == EmptyView {
    public init(title: String, message: String, size: Size = .regular,
                actionTitle: String? = nil, action: (() -> Void)? = nil,
                @ViewBuilder illustration: @escaping (Bool) -> Illustration) {
        self.init(title: title, message: message, size: size, actionTitle: actionTitle, action: action,
                  illustration: illustration, accessory: { EmptyView() })
    }
}

private struct EmptyStatePress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Shared pieces

/// Whether an illustration should move, and the finished frame when not.
private struct Arrival {
    let appeared: Bool
    let holdsStill: Bool

    var settled: Bool { holdsStill || appeared }

    /// A line showing up, the way output prints: quick, no bounce.
    func line(_ index: Int, after start: Double = 0.1) -> Animation? {
        holdsStill ? nil : .easeOut(duration: 0.16).delay(start + Double(index) * 0.12)
    }
}

private var panelFont: Font {
    #if os(macOS)
    .system(size: 11.5, design: .monospaced)
    #else
    .system(size: 13, design: .monospaced)
    #endif
}

/// The terminal-style panel the illustrations are set in.
private struct Panel<Content: View>: View {
    @Environment(\.companionPalette) private var palette
    var width: CGFloat = 228
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) { content }
            .font(panelFont)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(width: width, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(palette.raised))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(palette.hairline))
    }
}

// MARK: - Illustrations

/// A new conversation: a prompt gets typed, then Claude's first steps print.
public struct ConversationEmptyIllustration: View {
    @Environment(\.companionPalette) private var palette
    @Environment(\.motionLevel) private var motionLevel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let appeared: Bool
    /// How much of the prompt is typed so far.
    @State private var typed = 0

    public init(appeared: Bool) { self.appeared = appeared }

    private static let prompt = "fix the flaky login test"
    private static let steps = ["Read LoginTests.swift", "Run 42 tests"]

    public var body: some View {
        let holdsStill = reduceMotion || motionLevel == .still
        let count = holdsStill ? Self.prompt.count : typed
        let done = count >= Self.prompt.count
        Panel {
            HStack(spacing: 0) {
                Text("❯ ").foregroundStyle(palette.accent)
                Text(String(Self.prompt.prefix(count))).foregroundStyle(palette.ink)
                Rectangle().fill(palette.ink.opacity(0.75)).frame(width: 6, height: 13)
                    .opacity(done ? 0 : 1)
            }
            ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                HStack(spacing: 0) {
                    Text("✻\u{FE0E} ").foregroundStyle(palette.accent)
                    Text(step).foregroundStyle(palette.inkMuted)
                }
                .opacity(done ? 1 : 0)
                .animation(holdsStill ? nil : .easeOut(duration: 0.16).delay(0.15 + Double(index) * 0.22), value: done)
            }
        }
        .task(id: appeared) {
            guard appeared, !holdsStill else { return }
            try? await Task.sleep(for: .milliseconds(250))
            for count in 1...Self.prompt.count {
                try? await Task.sleep(for: .milliseconds(32))
                if Task.isCancelled { return }
                typed = count
            }
        }
    }
}

/// Projects as a folder listing, one of them picked.
public struct ProjectsEmptyIllustration: View {
    @Environment(\.companionPalette) private var palette
    @Environment(\.motionLevel) private var motionLevel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let appeared: Bool

    public init(appeared: Bool) { self.appeared = appeared }

    private static let rows: [(branch: String, name: String)] = [("├─ ", "api"), ("├─ ", "website"), ("└─ ", "ios-app")]

    public var body: some View {
        let arrival = Arrival(appeared: appeared, holdsStill: reduceMotion || motionLevel == .still)
        Panel(width: 196) {
            Text("~/Developer").foregroundStyle(palette.inkMuted)
                .opacity(arrival.settled ? 1 : 0)
                .animation(arrival.line(0), value: appeared)
            ForEach(Array(Self.rows.enumerated()), id: \.offset) { index, row in
                let picked = index == 1
                HStack(spacing: 0) {
                    Text(row.branch).foregroundStyle(palette.inkMuted.opacity(0.7))
                    Text(row.name).foregroundStyle(picked ? palette.accent : palette.ink)
                        .fontWeight(picked ? .semibold : .regular)
                    Spacer(minLength: 0)
                }
                .background(palette.accent.opacity(picked ? 0.14 : 0).padding(.horizontal, -5).padding(.vertical, -2))
                .opacity(arrival.settled ? 1 : 0)
                .animation(arrival.line(index + 1), value: appeared)
            }
        }
    }
}

/// Claude sessions as a status listing: one working, one waiting on you,
/// one done.
public struct SessionsEmptyIllustration: View {
    @Environment(\.companionPalette) private var palette
    @Environment(\.motionLevel) private var motionLevel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let appeared: Bool

    public init(appeared: Bool) { self.appeared = appeared }

    public var body: some View {
        let arrival = Arrival(appeared: appeared, holdsStill: reduceMotion || motionLevel == .still)
        let rows: [(name: String, status: String, color: Color)] = [
            ("api", "working", palette.working),
            ("website", "needs you", palette.waiting),
            ("ios-app", "done", palette.done),
        ]
        Panel {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(spacing: 8) {
                    Circle().fill(row.color).frame(width: 7, height: 7)
                    Text(row.name).foregroundStyle(palette.ink)
                    Spacer(minLength: 8)
                    Text(row.status).foregroundStyle(palette.inkMuted)
                }
                .opacity(arrival.settled ? 1 : 0)
                .animation(arrival.line(index), value: appeared)
            }
        }
    }
}

/// A clean working tree, as `git status` reports it.
public struct ChangesEmptyIllustration: View {
    @Environment(\.companionPalette) private var palette
    @Environment(\.motionLevel) private var motionLevel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let appeared: Bool
    /// The branch checked out, when it's known.
    var branch: String?

    public init(appeared: Bool, branch: String? = nil) {
        self.appeared = appeared
        self.branch = branch
    }

    public var body: some View {
        let arrival = Arrival(appeared: appeared, holdsStill: reduceMotion || motionLevel == .still)
        let lines: [Text] = [
            Text("$ ").foregroundColor(palette.accent) + Text("git status").foregroundColor(palette.ink),
            Text("On branch ").foregroundColor(palette.inkMuted) + Text(branch ?? "main").foregroundColor(palette.ink),
            Text("nothing to commit").foregroundColor(palette.inkMuted),
            Text("working tree clean").foregroundColor(palette.done),
        ]
        Panel(width: 204) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                line
                    .truncationMode(.middle)
                    .opacity(arrival.settled ? 1 : 0)
                    .animation(arrival.line(index), value: appeared)
            }
        }
    }
}

/// A diff with nothing in it, as `git diff --stat` or `git show --stat`
/// would sum it up.
public struct DiffEmptyIllustration: View {
    @Environment(\.companionPalette) private var palette
    @Environment(\.motionLevel) private var motionLevel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let appeared: Bool
    /// The command that would show this, like "git diff --stat".
    var command: String

    public init(appeared: Bool, command: String = "git diff --stat") {
        self.appeared = appeared
        self.command = command
    }

    public var body: some View {
        let arrival = Arrival(appeared: appeared, holdsStill: reduceMotion || motionLevel == .still)
        let lines: [Text] = [
            Text("$ ").foregroundColor(palette.accent) + Text(command).foregroundColor(palette.ink),
            Text("0 files changed").foregroundColor(palette.inkMuted),
            Text("0 insertions(").foregroundColor(palette.inkMuted) + Text("+").foregroundColor(palette.done) + Text(")").foregroundColor(palette.inkMuted),
            Text("0 deletions(").foregroundColor(palette.inkMuted) + Text("-").foregroundColor(.red) + Text(")").foregroundColor(palette.inkMuted),
        ]
        Panel(width: 204) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                line
                    .opacity(arrival.settled ? 1 : 0)
                    .animation(arrival.line(index), value: appeared)
            }
        }
    }
}

/// A page Claude published, as the first lines of its markup.
public struct ArtifactsEmptyIllustration: View {
    @Environment(\.companionPalette) private var palette
    @Environment(\.motionLevel) private var motionLevel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let appeared: Bool

    public init(appeared: Bool) { self.appeared = appeared }

    public var body: some View {
        let arrival = Arrival(appeared: appeared, holdsStill: reduceMotion || motionLevel == .still)
        let tag = palette.code
        let lines: [Text] = [
            Text("<main>").foregroundColor(tag),
            Text("  <h1>").foregroundColor(tag) + Text("Dashboard").foregroundColor(palette.ink) + Text("</h1>").foregroundColor(tag),
            Text("  <canvas ").foregroundColor(tag) + Text("id=").foregroundColor(palette.inkMuted) + Text("\"chart\"").foregroundColor(palette.ink) + Text(" />").foregroundColor(tag),
            Text("</main>").foregroundColor(tag),
        ]
        Panel {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                line
                    .opacity(arrival.settled ? 1 : 0)
                    .animation(arrival.line(index), value: appeared)
            }
        }
    }
}

#Preview("Conversation") {
    EmptyStateScaffold(title: "Ready when you are",
                       message: "Tell your agent what to work on. Type `/` for commands, or `@` to point it at a file.") {
        ConversationEmptyIllustration(appeared: $0)
    }
}

#Preview("Projects") {
    EmptyStateScaffold(title: "No Project Selected", message: "Add a project folder, or drag one into the sidebar.",
                       actionTitle: "Add Project…", action: {}) {
        ProjectsEmptyIllustration(appeared: $0)
    }
}
