import BenchKit
import SwiftUI

/// What a project shows when it has no tabs open: the project itself, a
/// big way to start Claude, the other ways in, and the last few
/// conversations to pick back up. Used for this Mac's projects and other
/// Macs' alike.
struct ProjectStartView<Icon: View>: View {
    /// A past conversation, ready to resume.
    struct Recent: Identifiable {
        var id: String
        var title: String
        var detail: String?
        var modified: Date
        var isOpen: Bool
    }

    /// A secondary way in, like a shell or an agent.
    struct Action: Identifiable {
        var id: String { title }
        var title: String
        var symbol: String
        var shortcut: String?
        var tint: Color?
        var monospaced = false
        var run: () -> Void
    }

    let icon: Icon
    let name: String
    var branch: String?
    /// "on M6 mini", for another Mac's project.
    var place: String?
    /// "⌘T", where the keyboard shortcut works.
    var startShortcut: String?
    let start: () -> Void
    /// The agent the big button starts.
    var agentName = "Claude"
    var agentSymbol = "sparkle"
    var actions: [Action] = []
    /// Your one-click commands, like the dev server or ssh.
    var shortcuts: [Action] = []
    /// Ends the shortcuts with a link to edit them in Settings.
    var editsShortcuts = false
    /// Nil while loading.
    var recents: [Recent]?
    var resume: (Recent) -> Void = { _ in }
    /// The project's own color, from its icon, which the page glows in. Nil
    /// (a grey icon) uses the theme's accent.
    var tint: Color?

    @Environment(\.motionLevel) private var motionLevel
    private var reduceMotion: Bool { motionLevel == .still }
    @Environment(AppStore.self) private var store
    @State private var appeared = false

    private var palette: CompanionPalette { TerminalTheme.shared.chatPalette }

    var body: some View {
        ZStack {
            palette.canvas
            glow
            GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    header
                    startButton
                        .padding(.top, 28)
                    if !actions.isEmpty {
                        // Room for the chips on one line where the pane has
                        // it, wider than the column the rest keeps to.
                        actionRow
                            .frame(width: max(200, min(620, proxy.size.width - 64)))
                            .padding(.top, 14)
                    }
                    if !shortcuts.isEmpty || editsShortcuts {
                        shortcutRow
                            .padding(.top, 8)
                    }
                    if let recents, !recents.isEmpty {
                        recentList(recents)
                            .padding(.top, 44)
                    }
                }
                .frame(maxWidth: 460)
                .padding(.horizontal, 32)
                .padding(.vertical, 56)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared || reduceMotion ? 0 : 6)
            }
            .scrollBounceBehavior(.basedOnSize)
            }
        }
        .onAppear {
            // Quick: this page comes up with every new tab.
            withAnimation(.easeOut(duration: 0.2)) { appeared = true }
        }
    }

    private var glow: some View {
        // Each project's page in its own light. The glow is the only
        // color here, so the button below it is the neutral accent.
        ClaudeGlow(color: tint ?? palette.accent, center: UnitPoint(x: 0.5, y: 0.34))
    }

    private var header: some View {
        VStack(spacing: 14) {
            icon
                .frame(width: 76, height: 76)
                .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
                .scaleEffect(appeared || reduceMotion ? 1 : 0.92)
            Text(name)
                .font(.ui(size: 26, weight: .semibold))
                .foregroundStyle(palette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            if branch != nil || place != nil {
                HStack(spacing: 10) {
                    if let branch {
                        Label(branch, systemImage: "arrow.triangle.branch")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let place {
                        Text(place)
                    }
                }
                .font(.ui(size: 12, weight: .medium))
                .foregroundStyle(palette.inkMuted)
                .labelStyle(TightLabel())
            }
        }
    }

    private var startButton: some View {
        Button(action: start) {
            HStack(spacing: 8) {
                Image(systemName: agentSymbol)
                    .font(.ui(size: 13, weight: .semibold))
                Text("Start \(agentName)")
                    .font(.ui(size: 14, weight: .semibold))
                if let startShortcut {
                    Text(startShortcut)
                        .font(.ui(size: 12, weight: .medium))
                        .opacity(0.65)
                }
            }
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 22)
            .frame(height: 40)
            .background(Capsule().fill(Theme.accent.gradient).shadow(color: .black.opacity(0.22), radius: 12, y: 5))
            .contentShape(Capsule())
        }
        .buttonStyle(PressButtonStyle())
    }

    /// Wraps onto a second line when the chips don't fit side by side.
    private var actionRow: some View {
        FlowLayout(spacing: 8) {
            ForEach(actions) { action in
                Button(action: action.run) { chip(action) }
                    .buttonStyle(PressButtonStyle())
            }
        }
    }

    private var shortcutRow: some View {
        FlowLayout(spacing: 8) {
            ForEach(shortcuts) { action in
                Button(action: action.run) { chip(action) }
                    .buttonStyle(PressButtonStyle())
                    .help("New tab running \(action.title)")
            }
            if editsShortcuts {
                Button {
                    store.settingsSection = .shortcuts
                } label: {
                    Text("Edit Shortcuts…")
                        .font(.ui(size: 12, weight: .medium))
                        .foregroundStyle(palette.inkMuted)
                        .padding(.horizontal, 8)
                        .frame(height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
            }
        }
    }

    private func chip(_ action: Action) -> some View {
        HStack(spacing: 6) {
            Image(systemName: action.symbol)
                .font(.ui(size: 11, weight: .semibold))
                .foregroundStyle(action.tint ?? palette.ink.opacity(0.85))
            Text(action.title)
                .font(.ui(size: 12, weight: .medium, design: action.monospaced ? .monospaced : .default))
                .lineLimit(1)
            if let shortcut = action.shortcut {
                Text(shortcut)
                    .font(.ui(size: 11))
                    .foregroundStyle(palette.inkMuted.opacity(0.8))
            }
        }
        .foregroundStyle(palette.ink.opacity(0.85))
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Capsule().fill(palette.ink.opacity(0.06)))
        .overlay(Capsule().strokeBorder(palette.hairline))
        .contentShape(Capsule())
    }

    private func recentList(_ recents: [Recent]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pick up where you left off")
                .font(.ui(size: 11, weight: .semibold))
                .foregroundStyle(palette.inkMuted)
                .padding(.leading, 4)
            VStack(spacing: 0) {
                ForEach(Array(recents.prefix(4).enumerated()), id: \.element.id) { index, recent in
                    if index > 0 {
                        Rectangle().fill(palette.hairline).frame(height: 1).padding(.leading, 14)
                    }
                    RecentRow(recent: recent, palette: palette) { resume(recent) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(palette.surface.opacity(0.7)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(palette.hairline))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

private struct RecentRow<Icon: View>: View {
    let recent: ProjectStartView<Icon>.Recent
    let palette: CompanionPalette
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(recent.title)
                        .font(.ui(size: 13, weight: .medium))
                        .foregroundStyle(palette.ink)
                        .lineLimit(1)
                    if let detail = recent.detail {
                        Text(detail)
                            .font(.ui(size: 12))
                            .foregroundStyle(palette.inkMuted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text(recent.modified, format: .relative(presentation: .named))
                    .font(.ui(size: 11))
                    .foregroundStyle(palette.inkMuted)
                    .lineLimit(1)
                    .opacity(isHovering ? 0 : 1)
                    .overlay(alignment: .trailing) {
                        Text(recent.isOpen ? "Open" : "Resume")
                            .font(.ui(size: 11, weight: .semibold))
                            .foregroundStyle(palette.ink)
                            .fixedSize()
                            .opacity(isHovering ? 1 : 0)
                    }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(palette.ink.opacity(isHovering ? 0.05 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help(recent.isOpen ? "Switch to the tab it's open in" : "Resume this conversation in a new tab")
    }
}

/// Shrinks a little while pressed.
struct PressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// An icon and title with less space between them.
private struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.ui(size: 10, weight: .semibold))
            configuration.title
        }
    }
}

/// Lays its views out in centered rows, wrapping when a row is full.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.midX - row.width / 2
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.indices.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

/// A soft wash of Claude's color, for start pages and the welcome.
struct ClaudeGlow: View {
    let color: Color
    var center = UnitPoint(x: 0.5, y: 0.4)
    var reach: CGFloat = 0.42
    @Environment(\.motionLevel) private var motionLevel
    /// Calm stops it too: it covers most of the window, so breathing kept
    /// the window server redrawing it as hard as a working agent's row.
    private var reduceMotion: Bool { motionLevel != .full }

    var body: some View {
        if reduceMotion {
            GeometryReader { proxy in
                RadialGradient(colors: [color.opacity(0.13), color.opacity(0)],
                               center: center, startRadius: 0,
                               endRadius: max(proxy.size.width, proxy.size.height) * reach)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        } else {
            // Brightens and dims by Core Animation. Animating the gradient
            // in SwiftUI had the start page laying out on every frame.
            LayerMotion(kind: .glow(NSColor(color), center: CGPoint(x: center.x, y: center.y), reach: reach))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
