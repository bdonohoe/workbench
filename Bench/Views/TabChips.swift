import AppKit
import BenchKit
import SwiftUI

/// One tab in a project's tab row, whether the project is on this Mac or on
/// another one. The caller decides what the tab is (its symbol, tint and
/// title) and what sits beside the title. Drawing lives here so the two
/// rows can't drift apart.
///
/// Tabs are plain text in a row at the top of the card: the open one is
/// brighter, with a short underline. What a tab's program is doing shows
/// as a word after its title ("Working", "Needs you"), and the close button
/// shows at its end under the pointer.
struct TabChip<Badges: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let isSelected: Bool
    /// Keeps the close button showing when the tab isn't hovered, for the
    /// other side of the split you're in.
    let showsClose: Bool
    /// False hides the close button altogether, for tabs the other Mac
    /// doesn't let us close.
    let canClose: Bool
    /// The tooltip, when there's more to say than the title.
    let help: String?
    let select: () -> Void
    let close: () -> Void
    let badges: Badges
    /// What the tab's program is doing, shown as a word.
    var activity: TabActivity = .idle
    /// A preview tab, which the next diff replaces: its title is in italics.
    var isPreview = false
    /// Half of a split pair: the pair draws the underline across both, so
    /// this one draws none of its own.
    var embedded = false
    /// Set while the tab's name is being edited, which swaps the title for
    /// a text field.
    var rename: TabChipRename?
    @State private var isHovering = false

    init(symbol: String, tint: Color, title: String, isSelected: Bool, showsClose: Bool,
         canClose: Bool = true, help: String? = nil, activity: TabActivity = .idle, isPreview: Bool = false,
         embedded: Bool = false, rename: TabChipRename? = nil, select: @escaping () -> Void, close: @escaping () -> Void,
         @ViewBuilder badges: () -> Badges) {
        self.symbol = symbol
        self.tint = tint
        self.title = title
        self.isSelected = isSelected
        self.showsClose = showsClose
        self.canClose = canClose
        self.help = help
        self.activity = activity
        self.isPreview = isPreview
        self.embedded = embedded
        self.rename = rename
        self.select = select
        self.close = close
        self.badges = badges()
    }

    var body: some View {
        // `.help` has no optional form, and an empty tooltip isn't the same
        // as none, so it's only attached when there is one.
        if let help {
            chip.help(help)
        } else {
            chip
        }
    }

    private var chip: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.ui(size: Theme.TypeScale.meta))
                .foregroundStyle(tint)
                .allowsHitTesting(false)
            if let rename {
                TabChipNameField(rename: rename, isSelected: isSelected)
            } else {
                Text(title)
                    .font(.ui(size: Theme.TypeScale.bodySmall, weight: isSelected ? .semibold : .regular))
                    .italic(isPreview)
                    .foregroundStyle(isSelected ? Color.primary : isHovering ? Color.primary.opacity(0.85) : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: TabChipMetrics.maxTitleWidth, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                    .allowsHitTesting(false)
            }
            if let status = TabStatusWord(activity: activity) {
                status
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            badges
            if canClose {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.ui(size: 8.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(isHovering ? Theme.Fill.hover : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                // Its room is always kept, so a tab doesn't change width
                // as the pointer passes over it.
                .opacity(isHovering || showsClose ? 1 : 0)
                .allowsHitTesting(isHovering || showsClose)
                .help("Close tab")
                .accessibilityLabel("Close tab")
            }
        }
        .padding(.leading, embedded ? 4 : TabChipMetrics.sidePadding)
        .padding(.trailing, embedded ? 2 : TabChipMetrics.sidePadding - 6)
        .frame(height: TabChipMetrics.height)
        // A click anywhere on the tab, not only on its title, selects it.
        .background {
            Button(action: select) { Color.clear.contentShape(Rectangle()) }
                .buttonStyle(.plain)
        }
        .overlay(alignment: .bottom) {
            if !embedded { TabUnderline(isOpen: isSelected) }
        }
        .onHover { isHovering = $0 }
        .animation(Theme.Motion.hover, value: isHovering)
        .animation(Theme.Motion.hover, value: activity)
    }
}

/// What a tab's program is doing, as a short colored word after its title.
/// Nothing when it's idle.
private struct TabStatusWord: View {
    let text: String
    let color: Color

    init?(activity: TabActivity) {
        switch activity {
        case .working: (text, color) = ("Working", Theme.Status.working)
        case .remoteWorking: (text, color) = ("Working", Theme.Status.remote)
        case .waiting: (text, color) = ("Needs you", Theme.Status.waiting)
        case .done: (text, color) = ("Done", Theme.Status.done)
        case .attention: (text, color) = ("Ping", Theme.Status.attention)
        case .idle: return nil
        }
    }

    var body: some View {
        Text(text)
            .font(.ui(size: Theme.TypeScale.meta, weight: .semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
    }
}

/// The line under the open tab, along the row's bottom edge.
struct TabUnderline: View {
    let isOpen: Bool

    var body: some View {
        // Which tab is open changes at once, even while tabs slide to make
        // room, so the old and the new line are never both half there.
        if isOpen {
            Rectangle()
                .fill(Theme.accent)
                .frame(height: 2)
                .padding(.horizontal, 4)
                .transition(.identity)
        }
    }
}

/// A tab's name while it's being edited: what's in the field to begin
/// with, the tab's own name to show when the field is empty, and what to
/// do with the result (nil to keep the old name).
struct TabChipRename {
    let placeholder: String
    let name: String
    let finish: (String?) -> Void
}

/// Edits a tab's name in place, as the sidebar does for projects. Return
/// or clicking away saves it, Escape keeps the old one, and an empty name
/// goes back to the tab's own.
private struct TabChipNameField: View {
    let rename: TabChipRename
    let isSelected: Bool
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(rename.placeholder, text: $draft)
            .textFieldStyle(.plain)
            .font(.ui(size: Theme.TypeScale.bodySmall, weight: isSelected ? .semibold : .regular))
            .fixedSize()
            .frame(minWidth: 60, alignment: .leading)
            .focused($focused)
            .onAppear {
                draft = rename.name
                focused = true
            }
            .onSubmit { rename.finish(draft) }
            .onExitCommand { rename.finish(nil) }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { rename.finish(draft) }
            }
    }
}

/// The row of tabs at the top of the card, with the ＋ after them, and a
/// hairline under it. The tabs scroll sideways when there are too many.
/// The card runs up to the top of the window, so this row is also the
/// window's title bar here: `leading` and `end` hold the window's buttons
/// (the sidebar's when it's collapsed, the right panel's when it's hidden)
/// and the controls for the open tab, and the empty space drags the window.
struct TabRow<Leading: View, Tabs: View, Trailing: View, End: View>: View {
    @ViewBuilder let leading: Leading
    @ViewBuilder let tabs: Tabs
    @ViewBuilder let trailing: Trailing
    @ViewBuilder let end: End

    var body: some View {
        HStack(spacing: 2) {
            leading
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .bottom, spacing: 0) {
                    tabs
                }
                .padding(.horizontal, 6)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            trailing
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                end
            }
            .fixedSize()
        }
        .frame(height: TabChipMetrics.rowHeight)
        .padding(.trailing, 8)
        .background(WindowTitleArea())
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Fill.hairline).frame(height: 1)
        }
    }
}

extension TabRow where Leading == EmptyView, End == EmptyView {
    init(@ViewBuilder tabs: () -> Tabs, @ViewBuilder trailing: () -> Trailing) {
        self.init(leading: { EmptyView() }, tabs: tabs, trailing: trailing, end: { EmptyView() })
    }
}

/// The window's buttons at the ends of the card's tab row, now that the
/// card runs up to the top of the window.
enum CardBand {
    /// The card's top edge, from the top of the window, so the tab row's
    /// middle lines up with the traffic lights and the side columns' bands.
    static var topInset: CGFloat { WindowChrome.rowMidY - TabChipMetrics.rowHeight / 2 }
    /// How far the traffic lights move right to sit on the card, when the
    /// sidebar is collapsed to its icons.
    static var trafficLightsShift: CGFloat { ProjectRail.width + TerminalCard.margin }
}

/// The sidebar's buttons at the start of the tab row when it's collapsed
/// to icons, after room for the traffic lights, which move onto the card
/// then (the icons' column is too thin for them).
struct CardBandLeading: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if store.sidebarVisibility == .detailOnly {
            Spacer().frame(width: WindowChrome.trafficLightsWidth - 4)
            SidebarBandButtons()
            Divider().frame(height: 16).padding(.horizontal, 4)
        }
    }
}

/// Feedback and the right panel's button at the end of the tab row, when
/// the right panel is hidden (when it's open they sit over it).
struct CardBandTrailing: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if !store.showsChanges {
            Divider().frame(height: 16).padding(.horizontal, 4)
            WindowTrailingButtons()
        }
    }
}

/// Two tabs shown together in a split, as one tab: the two names side by
/// side with one underline under both when the pair is open. The mark
/// between them is a menu to flip the split, swap its sides, or unsplit
/// the two tabs again. A tab's right-click menu lists the same items in
/// the same words.
struct SplitTabPair<First: View, Second: View>: View {
    let axis: TabSplit.Axis
    /// The pair is what's on screen.
    let isOpen: Bool
    let setAxis: (TabSplit.Axis) -> Void
    let swap: () -> Void
    let separate: () -> Void
    @ViewBuilder let first: First
    @ViewBuilder let second: Second
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 0) {
            first
            Menu {
                Button {
                    setAxis(.sideBySide)
                } label: {
                    Label("Side by Side", systemImage: "rectangle.split.2x1")
                }
                .disabled(axis == .sideBySide)
                Button {
                    setAxis(.stacked)
                } label: {
                    Label("Stacked", systemImage: "rectangle.split.1x2")
                }
                .disabled(axis == .stacked)
                Button("Swap Sides", action: swap)
                Divider()
                Button("Unsplit", action: separate)
            } label: {
                Image(systemName: axis == .sideBySide ? "rectangle.split.2x1" : "rectangle.split.1x2")
                    .font(.ui(size: 11, weight: .medium))
                    .foregroundStyle(isOpen ? Color.primary.opacity(0.7) : Color.secondary)
                    .frame(width: 22, height: 20)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isHovering ? Theme.Fill.pressed : Color.clear))
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(height: TabChipMetrics.height)
            .onHover { isHovering = $0 }
            .help("Split: flip it, swap sides, or unsplit")
            second
        }
        .padding(.horizontal, TabChipMetrics.sidePadding - 4)
        .overlay(alignment: .bottom) { TabUnderline(isOpen: isOpen) }
        .fixedSize()
        .animation(Theme.Motion.hover, value: isHovering)
    }
}

/// How a tab comes and goes. A new tab opens a gap for itself, the tabs
/// after it sliding over, and fades in as the gap opens. A closing
/// tab shrinks and fades where it was while its neighbors close up over
/// it: SwiftUI takes a removed view out of the layout at once, so it
/// can't hold its gap open on the way out.
struct TabTransition: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        let shown = phase.isIdentity
        let scale: CGFloat = phase == .willAppear ? 0.9 : 0.8
        TabWidthReveal(progress: shown ? 1 : 0) {
            content
                .scaleEffect(shown ? 1 : scale, anchor: .bottom)
                .opacity(shown ? 1 : 0)
        }
    }
}

/// Takes up `progress` of its content's width, keeping the content at
/// full size from the leading edge, so a tab can open its gap gradually.
/// (Centered, the first tab's left side was cut off by the scroll view.)
private struct TabWidthReveal: Layout {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews.first?.sizeThatFits(Self.ideal(proposal)) ?? .zero
        return CGSize(width: size.width * progress, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let content = subviews.first else { return }
        let size = content.sizeThatFits(Self.ideal(proposal))
        content.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(size))
    }

    /// The tab's own width, whatever the stack offers: offered its
    /// shrinking gap, the title would cut off while the tab opens.
    private static func ideal(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: nil, height: proposal.height)
    }
}

enum TabChipMetrics {
    /// The row the tabs sit in, at the top of the card.
    static let rowHeight: CGFloat = 36
    static let height: CGFloat = 36
    /// Space at each end of a tab, which is also the gap between two.
    static let sidePadding: CGFloat = 12
    /// Longer titles end in "…".
    static let maxTitleWidth: CGFloat = 200
}

/// A button in a tab bar: an action, not a place, so it has no fill until
/// the pointer is on it. Every one is the same height, with or without a
/// label.
struct BarButton: View {
    let symbol: String
    var title: String?
    var tint: Color = .secondary
    /// For labels that are commands, like "bun run dev" or "ssh".
    var monospaced = false
    let action: () -> Void
    @State private var isHovering = false
    @Environment(\.isNarrowWindow) private var isNarrow

    init(symbol: String, title: String? = nil, tint: Color = .secondary, monospaced: Bool = false, action: @escaping () -> Void) {
        self.symbol = symbol
        self.title = title
        self.tint = tint
        self.monospaced = monospaced
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.ui(size: Theme.TypeScale.meta, weight: .medium))
                    .foregroundStyle(tint)
                if let title, !isNarrow {
                    Text(title)
                        .font(.ui(size: Theme.TypeScale.bodySmall, weight: .medium, design: monospaced ? .monospaced : .default))
                        .foregroundStyle(.primary.opacity(0.85))
                }
            }
            .padding(.horizontal, title == nil || isNarrow ? 0 : 9)
            .frame(minWidth: BarButtonMetrics.height, minHeight: BarButtonMetrics.height)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control + 1, style: .continuous)
                    .fill(isHovering ? Theme.Fill.pressed : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressableChip)
        .fixedSize()
        .onHover { isHovering = $0 }
        .animation(Theme.Motion.hover, value: isHovering)
    }
}

enum BarButtonMetrics {
    static let height: CGFloat = 28
}

#if DEBUG
/// A tab bar on its card, drawn to PNGs in light and dark, for checking
/// the tabs' look. BENCH_RENDER_TABS=<folder>.
enum TabStripPreview {
    static func render(to folder: URL) {
        _ = NSApplication.shared
        render(scene(width: 900), to: folder, name: "tabs", width: 900)
        render(scene(width: 520), to: folder, name: "tabs-narrow", width: 520)
    }

    private static func chip(_ symbol: String, _ tint: Color, _ title: String, open: Bool = false,
                             activity: TabActivity = .idle, preview: Bool = false, embedded: Bool = false) -> some View {
        TabChip(symbol: symbol, tint: tint, title: title, isSelected: open, showsClose: false, activity: activity,
                isPreview: preview, embedded: embedded, select: {}, close: {}) { EmptyView() }
    }

    private static func scene(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: WindowChrome.bandHeight)
            VStack(spacing: 0) {
                TabRow {
                    chip("sparkle", .orange, "Claude", open: true, activity: .working)
                    chip("terminal", .secondary, "Shell")
                    chip("doc.text", .indigo, "README.md", preview: true)
                    SplitTabPair(axis: .sideBySide, isOpen: false, setAxis: { _ in }, swap: {}, separate: {}) {
                        chip("sparkle", .orange, "Claude", activity: .waiting, embedded: true)
                    } second: {
                        chip("sparkle", .orange, "Tests", embedded: true)
                    }
                    chip("sparkle", .orange, "Codex", activity: .done)
                } trailing: {
                    Image(systemName: "plus").font(.ui(size: 12, weight: .medium)).frame(width: 28, height: 28)
                }
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .canvasCard()
            .padding([.horizontal, .bottom], TerminalCard.margin)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private static func render(_ scene: some View, to folder: URL, name: String, width: CGFloat) {
        let size = NSSize(width: width, height: 150)
        let view = scene.frame(width: size.width, height: size.height)
        for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            host.setFrameSize(size)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("\(name)-\(mode).png"))
        }
    }
}
#endif
