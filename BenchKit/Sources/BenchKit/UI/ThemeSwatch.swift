import SwiftUI

/// A small card in a built-in theme's colors: sample text, a prompt, the
/// cursor, and the main ANSI colors. Settings on the Mac and the phone
/// show a row of these to pick from.
public struct ThemeSwatch: View {
    let theme: BuiltInTheme
    let isSelected: Bool
    var width: CGFloat

    public init(theme: BuiltInTheme, isSelected: Bool, width: CGFloat = 132) {
        self.theme = theme
        self.isSelected = isSelected
        self.width = width
    }

    public var body: some View {
        let bg = theme.background.color, fg = theme.foreground.color
        VStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    Text("Aa")
                        .font(.system(size: 19))
                        .foregroundStyle(fg)
                    Spacer(minLength: 2)
                    Text("~/")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(fg)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(theme.selection.color, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(theme.cursor.color)
                        .frame(width: 7, height: 17)
                }
                HStack(spacing: -3) {
                    ForEach(0..<8, id: \.self) { index in
                        Circle()
                            .fill(theme.palette[index == 0 ? 8 : index].color)
                            .frame(width: 13, height: 13)
                            .overlay(Circle().strokeBorder(bg, lineWidth: 1.5))
                    }
                }
            }
            .padding(10)
            .frame(width: width)
            .background(bg, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(fg.opacity(0.14), lineWidth: 1)
            )
            .padding(3)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: isSelected ? 2.5 : 0)
            )
            Text(theme.name)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(theme.name)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A row of swatches that scrolls sideways, keeping the chosen one in view.
public struct ThemeSwatchRow: View {
    let themes: [BuiltInTheme]
    @Binding var selection: String
    var width: CGFloat
    @State private var scroll = ScrollPosition()
    /// How far the row is scrolled, how wide it shows, and how wide it is.
    @State private var offset: CGFloat = 0
    @State private var visible: CGFloat = 0
    @State private var content: CGFloat = 0

    public init(themes: [BuiltInTheme], selection: Binding<String>, width: CGFloat = 132) {
        self.themes = themes
        _selection = selection
        self.width = width
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(themes) { theme in
                        Button { selection = theme.id } label: {
                            ThemeSwatch(theme: theme, isSelected: theme.id == selection, width: width)
                        }
                        .buttonStyle(.pressable)
                        .id(theme.id)
                    }
                }
                .padding(.vertical, 4)
                .padding(.bottom, 6)
            }
            .scrollPosition($scroll)
            .onScrollGeometryChange(for: [CGFloat].self) { geometry in
                [geometry.contentOffset.x, geometry.visibleRect.width, geometry.contentSize.width]
            } action: { _, values in
                offset = values[0]
                visible = values[1]
                content = values[2]
            }
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
            #if os(macOS)
            // A mouse without a sideways wheel can't scroll the row, so
            // arrows page through it.
            .overlay(alignment: .leading) {
                if offset > 1 { pageButton(forward: false) }
            }
            .overlay(alignment: .trailing) {
                if offset + visible < content - 1 { pageButton(forward: true) }
            }
            .animation(.easeOut(duration: 0.15), value: offset > 1)
            .animation(.easeOut(duration: 0.15), value: offset + visible < content - 1)
            #endif
        }
    }

    #if os(macOS)
    private func pageButton(forward: Bool) -> some View {
        Button {
            let page = max(visible - width, width)
            let target = min(max(offset + (forward ? page : -page), 0), max(content - visible, 0))
            withAnimation(.smooth(duration: 0.35)) { scroll.scrollTo(x: target) }
        } label: {
            Image(systemName: forward ? "chevron.right" : "chevron.left")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.12)))
                .shadow(color: .black.opacity(0.18), radius: 4, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(.pressable)
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
        .transition(.opacity)
        .help(forward ? "More themes" : "Previous themes")
        .accessibilityLabel(forward ? "Show more themes" : "Show previous themes")
    }
    #endif
}
