import BenchKit
import SwiftUI

// MARK: - Page

/// Settings › Appearance: a small Workbench window drawn in the chosen
/// colors and fonts, pinned at the top, with the settings that change it
/// scrolling underneath.
struct AppearanceSettingsPage: View {
    let section: SettingsSection

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(section.title)
                        .font(.ui(size: 22, weight: .semibold))
                    Text(section.subtitle)
                        .font(.ui(size: 13))
                        .foregroundStyle(.secondary)
                }
                AppearancePreview()
            }
            .padding([.horizontal, .top], 28)
            .padding(.bottom, 16)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider().opacity(0.6)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    AppearanceSettings()
                }
                .padding(28)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(TerminalTheme.shared.canvas)
        .navigationTitle("Settings")
    }
}

private struct AppearanceSettings: View {
    @AppStorage(FocusRingColor.key) private var focusRingColor = FocusRingColor.blue

    var body: some View {
        @Bindable var theme = TerminalTheme.shared
        @Bindable var appearance = AppAppearance.shared
        SettingsGroup(title: "Colors") {
            SettingsRow(title: "Appearance",
                        detail: "Keep Workbench light or dark whatever your Mac is set to, or follow it.") {
                Picker("Appearance", selection: $appearance.mode) {
                    ForEach(AppAppearance.Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            ThemeSettingsRows(theme: theme)
            SettingsRow(title: "Focused pane",
                        detail: "The ring around the side of a split you're typing in.",
                        more: "The colors come from your terminal theme, so they change when it does. The last one is your Mac's accent color instead.") {
                FocusRingPicker(selection: $focusRingColor)
            }
        }
        MotionSettings()
        SoundSettings()
        SettingsGroup(title: "App Icon") {
            AppIconSettingsRow()
        }
        InterfaceTextSettings()
        ChatTextSettings()
    }
}

/// How much Workbench moves on its own. Holding still saves the work of
/// redrawing the window every frame while agents are busy.
private struct MotionSettings: View {
    @AppStorage(MotionLevel.key) private var level = MotionLevel.standard
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    var body: some View {
        SettingsGroup(title: "Motion",
                      footer: "Anything that keeps moving makes your Mac redraw the window many times a second. Calm and Still let it rest, which saves energy while agents work.") {
            SettingsRow(title: "Animations", detail: detail) {
                Picker("Animations", selection: $level) {
                    ForEach(MotionLevel.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(systemReduceMotion)
            }
        }
    }

    private var detail: String {
        if systemReduceMotion { return "Reduce Motion is on in System Settings, so nothing moves on its own." }
        switch level {
        case .full: return "Working projects sparkle, waiting ones glow, and the start page shimmers."
        case .calm: return "Rows and the start page hold still. The small spinners and dots still move, so you can see an agent at work."
        case .still: return "Nothing moves on its own. Colors still show which projects are working, waiting, or done."
        }
    }
}

/// Workbench's two sounds, which one each is, and a way to hear them.
private struct SoundSettings: View {
    @AppStorage(Chime.enabledKey) private var playsSounds = false

    var body: some View {
        SettingsGroup(title: "Sounds") {
            SettingsRow("Play a sound when an agent finishes or needs you",
                        detail: "A short, quiet sound while Workbench is in front.",
                        more: "One sound when an agent finishes a turn that took a while or that you weren't watching, and another when it needs your answer in a tab you aren't looking at. When Workbench is in the background, the notification makes the sound instead.",
                        isOn: $playsSounds)
            ForEach(Chime.Kind.allCases, id: \.self) { kind in
                SettingsRow(title: kind.title) { SoundPicker(kind: kind) }
                    .disabled(!playsSounds)
            }
        }
    }
}

/// One sound's menu, and a button to hear it again. Picking a sound plays it.
private struct SoundPicker: View {
    let kind: Chime.Kind
    @AppStorage private var soundID: String

    init(kind: Chime.Kind) {
        self.kind = kind
        _soundID = AppStorage(wrappedValue: kind.defaultSound.id, kind.key)
    }

    private var sound: ChimeSound { ChimeSound(id: soundID) ?? kind.defaultSound }

    var body: some View {
        HStack(spacing: 6) {
            Picker(kind.title, selection: $soundID) {
                Section("Workbench") {
                    ForEach(ChimeSound.workbench) { Text($0.title).tag($0.id) }
                }
                Section("Mac") {
                    ForEach(ChimeSound.mac) { Text($0.title).tag($0.id) }
                }
                Divider()
                Text(ChimeSound.none.title).tag(ChimeSound.none.id)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .onChange(of: soundID) { Chime.preview(sound) }
            Button {
                Chime.preview(sound)
            } label: {
                Image(systemName: "speaker.wave.2")
            }
            .help("Play")
            .accessibilityLabel("Play \(sound.title)")
            .disabled(sound == .none)
        }
    }
}

/// The icons to pick from, with a note when only the Dock can change.
private struct AppIconSettingsRow: View {
    private let icons = AppIconManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AppIconPicker(selection: icons.choice, columns: AppIconChoice.allCases.count) { icons.select($0) }
            if icons.dockOnly {
                Text("Workbench couldn't change its icon in Finder, so the new icon only shows in the Dock while it's open. Moving Workbench to your Applications folder usually fixes this.")
                    .font(.ui(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("App icon")
    }
}

// MARK: - Colors

/// Where the colors come from, and for the built-in themes, which ones.
private struct ThemeSettingsRows: View {
    @Bindable var theme: TerminalTheme

    var body: some View {
        SettingsRow(title: "Theme", detail: detail) {
            Picker("Theme", selection: $theme.source) {
                ForEach(TerminalTheme.Source.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        if theme.source == .builtIn {
            ThemeGalleryRow(title: "Light Mode", themes: BuiltInTheme.light, selection: $theme.lightThemeID)
            ThemeGalleryRow(title: "Dark Mode", themes: BuiltInTheme.dark, selection: $theme.darkThemeID)
        }
    }

    private var detail: String {
        switch theme.source {
        case .ghostty:
            "Terminal tabs, sidebars, chat, and diffs all take your Ghostty theme's colors, light or dark. Change themes in your Ghostty config and Workbench follows."
        case .builtIn:
            switch AppAppearance.shared.mode {
            case .system:
                "Pick a theme for light mode and one for dark mode. Workbench switches with your Mac's appearance. Your Ghostty font and settings still apply."
            case .light:
                "Pick a theme for light mode and one for dark mode. Workbench is set to stay light, so it uses the light one. Your Ghostty font and settings still apply."
            case .dark:
                "Pick a theme for light mode and one for dark mode. Workbench is set to stay dark, so it uses the dark one. Your Ghostty font and settings still apply."
            }
        case .system:
            "Terminal tabs keep your Ghostty theme, and the rest of the window uses the Mac's usual colors."
        }
    }
}

/// One appearance's built-in themes, as a scrolling row of swatches.
private struct ThemeGalleryRow: View {
    let title: String
    let themes: [BuiltInTheme]
    @Binding var selection: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.ui(size: 13))
            ThemeSwatchRow(themes: themes, selection: $selection)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

// MARK: - Chat text

/// The size of the app's own text, outside conversations.
private struct InterfaceTextSettings: View {
    var body: some View {
        @Bindable var text = InterfaceText.shared
        SettingsGroup(title: "Interface Text") {
            SettingsRow(title: "Text size",
                        detail: "For the sidebar, tabs, Changes, Overview and Settings. Chat text has its own size below.") {
                Picker("Text size", selection: $text.size) {
                    ForEach(InterfaceText.Size.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }
}

/// The chat's fonts and text size. The preview above shows how they look.
private struct ChatTextSettings: View {
    @State private var families: [String] = []
    @State private var monospacedFamilies: [String] = []

    var body: some View {
        @Bindable var typography = ChatTypography.shared
        SettingsGroup(title: "Chat Text",
                      footer: "These only change agent conversations shown as chat. The terminal uses the font in your Ghostty config.") {
            SettingsRow(title: "Font", detail: "For messages and the agent's replies.") {
                FontFamilyPicker(title: "Font", selection: $typography.textFamily, systemName: "System", families: families)
            }
            SettingsRow(title: "Code font", detail: "For code blocks, commands, and file names.") {
                FontFamilyPicker(title: "Code font", selection: $typography.codeFamily, systemName: "System Monospaced", families: monospacedFamilies)
            }
            SettingsRow(title: "Text size",
                        detail: "You can also press ⌘+ and ⌘− while reading a chat, and ⌘0 to go back to the usual size.") {
                HStack(spacing: 8) {
                    if !typography.isDefaultSize {
                        Button("Reset") { typography.resetSize() }
                    }
                    ControlGroup {
                        Button { typography.zoomOut() } label: { Image(systemName: "textformat.size.smaller") }
                            .disabled(!typography.canZoomOut)
                            .help("Smaller")
                            .accessibilityLabel("Smaller text")
                        Button { typography.zoomIn() } label: { Image(systemName: "textformat.size.larger") }
                            .disabled(!typography.canZoomIn)
                            .help("Bigger")
                            .accessibilityLabel("Bigger text")
                    }
                    .fixedSize()
                    Text(typography.scale, format: .percent)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
                .fixedSize()
            }
        }
        .task {
            families = ChatTypography.allFamilies()
            monospacedFamilies = ChatTypography.monospacedFamilies()
        }
    }
}

/// A menu of font families, with the system's font first. The title is the
/// row's, spoken but not shown.
private struct FontFamilyPicker: View {
    let title: String
    @Binding var selection: String?
    let systemName: String
    let families: [String]

    var body: some View {
        Picker(title, selection: $selection) {
            Text(systemName).tag(String?.none)
            Divider()
            // A chosen font that's since been removed still shows, so the
            // menu doesn't look blank.
            if let selection, !families.contains(selection) {
                Text("\(selection) (not installed)").tag(String?.some(selection))
            }
            ForEach(families, id: \.self) { family in
                Text(family).tag(String?.some(family))
            }
        }
        .labelsHidden()
        .fixedSize()
    }
}

// MARK: - Preview

/// The colors the preview draws with: from a built-in theme directly, so
/// it can show light and dark side by side, or from the live terminal
/// theme for Ghostty and Mac colors.
private struct PreviewColors {
    var terminalBackground: Color
    var terminalText: Color
    /// The 16 ANSI colors.
    var ansi: [Color]
    var sidebar: Color
    var selectedRow: Color
    var chat: CompanionPalette
    var working: Color
    var ring: Color
    /// The appearance to draw in, or nil for the Mac's own.
    var scheme: ColorScheme?

    private static let fallbackANSI: [Color] = [.black, .red, .green, .yellow, .blue, .purple, .teal, .white,
                                                .gray, .red, .green, .yellow, .blue, .purple, .teal, .white]

    init(theme: BuiltInTheme, ring choice: FocusRingColor) {
        let bg = theme.background, fg = theme.foreground, dark = theme.isDark
        terminalBackground = bg.color
        terminalText = fg.color
        ansi = theme.palette.map(\.color)
        sidebar = bg.mixed(dark ? 0.045 : 0.035, with: fg).color
        selectedRow = dark ? bg.mixed(0.13, with: fg).color : bg.color
        chat = CompanionPalette.mac.themed(with: theme.terminalColors)
        working = theme.terminalColors.working?.color ?? ActivityBackground.claudeOrange
        scheme = dark ? .dark : .light
        // Matches TerminalTheme.focusRing, worked out from this theme.
        switch choice {
        case .system:
            ring = .accentColor
        case .cursor:
            ring = theme.cursor.readable(on: bg, contrast: 3).color
        default:
            let index = choice.ansiIndex ?? 4
            let normal = theme.palette[index], bright = theme.palette[index + 8]
            let preferred = dark ? bright : normal, other = dark ? normal : bright
            let pick = preferred.contrast(on: bg) < 1.8 && other.contrast(on: bg) > preferred.contrast(on: bg) ? other : preferred
            ring = pick.readable(on: bg, contrast: 3).color
        }
    }

    init(live theme: TerminalTheme, ring choice: FocusRingColor) {
        terminalBackground = Color(nsColor: theme.background ?? .textBackgroundColor)
        terminalText = Color(nsColor: theme.foreground ?? .labelColor)
        ansi = (0..<16).map { theme.ansiColor($0) ?? Self.fallbackANSI[$0] }
        sidebar = theme.panel ?? Color(nsColor: .windowBackgroundColor)
        selectedRow = theme.selectedRow ?? Color(nsColor: .controlBackgroundColor)
        chat = theme.chatPalette
        working = theme.working
        ring = theme.focusRing(choice)
        scheme = theme.colorScheme
    }
}

/// A small Workbench window in the chosen colors and fonts: a sidebar with
/// a project at work, Claude's chat on one side of a split and a terminal
/// on the other. Click a side to move the focus ring there.
private struct AppearancePreview: View {
    @Environment(\.colorScheme) private var systemScheme
    @AppStorage(FocusRingColor.key) private var focusRingColor = FocusRingColor.blue
    /// Which built-in theme to show: the one for light mode or for dark.
    /// Follows the Mac until you pick a theme for the other one.
    @State private var showsDark: Bool?
    @State private var focusesTerminal = false

    var body: some View {
        let theme = TerminalTheme.shared
        let dark = showsDark ?? (systemScheme == .dark)
        let builtIn = theme.source == .builtIn
        let colors = builtIn
            ? PreviewColors(theme: dark ? theme.darkTheme : theme.lightTheme, ring: focusRingColor)
            : PreviewColors(live: theme, ring: focusRingColor)
        // Picking a theme shows it, even for the appearance you're not in.
        let identity = [theme.source.rawValue, theme.lightThemeID, theme.darkThemeID, focusRingColor.rawValue,
                        dark ? "dark" : "light"].joined(separator: "/")

        VStack(alignment: .trailing, spacing: 8) {
            PreviewWindow(colors: colors, focusesTerminal: $focusesTerminal)
                .environment(\.colorScheme, colors.scheme ?? systemScheme)
                .animation(.easeInOut(duration: 0.3), value: identity)
            if builtIn {
                Picker("Preview", selection: Binding(get: { dark }, set: { value in withAnimation { showsDark = value } })) {
                    Label("Light", systemImage: "sun.max").tag(false)
                    Label("Dark", systemImage: "moon").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Preview light or dark mode")
            }
        }
        .onChange(of: theme.lightThemeID) { withAnimation { showsDark = false } }
        .onChange(of: theme.darkThemeID) { withAnimation { showsDark = true } }
        .onChange(of: systemScheme) { showsDark = nil }
    }
}

private struct PreviewWindow: View {
    let colors: PreviewColors
    @Binding var focusesTerminal: Bool

    private static let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
    private static let pane = RoundedRectangle(cornerRadius: 8, style: .continuous)

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 168)
                .background(colors.sidebar)
            Rectangle().fill(colors.chat.hairline).frame(width: 1)
            HStack(spacing: 8) {
                pane(focused: !focusesTerminal) { PreviewChat() }
                    .background(colors.chat.canvas)
                    .environment(\.companionPalette, colors.chat)
                    .environment(\.markdownFonts, ChatStyle.markdown)
                pane(focused: focusesTerminal) { PreviewTerminal(colors: colors) }
                    .background(colors.terminalBackground)
            }
            .padding(8)
            .background(colors.chat.canvas)
        }
        .frame(height: 220)
        .clipShape(Self.shape)
        .overlay(Self.shape.strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of Workbench in the chosen colors and fonts")
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                ForEach([Color.red, .yellow, .green], id: \.self) { color in
                    Circle().fill(color.opacity(0.85)).frame(width: 10, height: 10)
                }
            }
            .padding(.bottom, 12)
            Text("Projects")
                .font(.ui(size: 10, weight: .semibold))
                .foregroundStyle(colors.chat.inkMuted)
                .padding(.leading, 6)
                .padding(.bottom, 2)
            PreviewProjectRow(name: "Bench", symbol: "hammer", colors: colors, isSelected: true)
            PreviewProjectRow(name: "Pastry", symbol: "birthday.cake", colors: colors, isWorking: true)
            PreviewProjectRow(name: "Quick Notes", symbol: "note.text", colors: colors)
            Spacer(minLength: 0)
        }
        .padding(10)
    }

    private func pane<Content: View>(focused: Bool, @ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipShape(Self.pane)
            .overlay {
                if focused {
                    Self.pane.strokeBorder(colors.ring.opacity(0.9), lineWidth: 2)
                } else {
                    Self.pane.fill(colors.terminalBackground.opacity(0.3))
                }
            }
            .contentShape(Self.pane)
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.15)) { focusesTerminal.toggle() }
            }
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}

private struct PreviewProjectRow: View {
    let name: String
    let symbol: String
    let colors: PreviewColors
    var isSelected = false
    var isWorking = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.ui(size: 10, weight: .medium))
                .frame(width: 14)
                .foregroundStyle(isWorking ? colors.working : colors.chat.inkMuted)
            Text(name)
                .font(.ui(size: Theme.TypeScale.bodySmall, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(colors.chat.ink)
                .lineLimit(1)
            Spacer(minLength: 0)
            if isWorking { PreviewSpinner(color: colors.working) }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? colors.selectedRow : isWorking ? colors.working.opacity(0.12) : .clear)
                .shadow(color: .black.opacity(isSelected ? 0.1 : 0), radius: 2, y: 1)
        }
    }
}

/// A turning arc, like a busy row's.
private struct PreviewSpinner: View {
    let color: Color

    var body: some View {
        LayerMotion(kind: .arc(NSColor(color), lineWidth: 1.6))
            .frame(width: 9, height: 9)
    }
}

/// A short exchange in the chat's fonts and size.
private struct PreviewChat: View {
    @Environment(\.companionPalette) private var palette

    var body: some View {
        let scale = ChatTypography.shared.scale
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer(minLength: 30)
                Text("Rename Free play to Endless")
                    .font(ChatStyle.body)
                    .foregroundStyle(palette.onAccent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(palette.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            HStack(alignment: .top, spacing: 8) {
                ClaudeMark(size: 13 * scale)
                    .padding(.top, 2)
                MarkdownText(text: """
                Done. The mode is now `Endless`:

                ```swift
                let mode = "Endless"
                ```
                """)
                .font(ChatStyle.body)
                .lineSpacing(2)
                .foregroundStyle(palette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
    }
}

/// A build in the terminal's colors.
private struct PreviewTerminal: View {
    let colors: PreviewColors

    var body: some View {
        let font = Font.ui(size: 11, design: .monospaced)
        VStack(alignment: .leading, spacing: 3) {
            line([("~/Apps/Pastry", 4), (" on ", nil), ("main", 5)])
            line([("$ ", 2), ("make build", nil)])
            line([("Compiling ", nil), ("GameMode.swift", 6)])
            line([("warning: ", 3), ("unused variable 'score'", nil)])
            line([("✓ BUILD SUCCEEDED", 2)])
            HStack(spacing: 0) {
                Text("$ ").foregroundStyle(colors.ansi[2])
                LayerMotion(kind: .blink(NSColor(colors.terminalText.opacity(0.85))))
                    .frame(width: 6.5, height: 13)
            }
        }
        .font(font)
        .foregroundStyle(colors.terminalText)
        .padding(12)
    }

    /// Runs of text, each in an ANSI color or the text color.
    private func line(_ runs: [(String, Int?)]) -> some View {
        var text = AttributedString()
        for (words, color) in runs {
            var run = AttributedString(words)
            run.foregroundColor = color.map { colors.ansi[$0] } ?? colors.terminalText
            text += run
        }
        return Text(text).lineLimit(1)
    }
}
