import SwiftUI

/// A grid of the app's icons to pick from, in Settings on the Mac and the
/// phone. Each app decides what picking one does.
public struct AppIconPicker: View {
    let selection: AppIconChoice
    let onSelect: (AppIconChoice) -> Void
    var iconSize: CGFloat
    /// Six icons: 3 makes two even rows, 6 makes one.
    var columns: Int

    public init(selection: AppIconChoice, iconSize: CGFloat = 56, columns: Int = 3,
                onSelect: @escaping (AppIconChoice) -> Void) {
        self.selection = selection
        self.iconSize = iconSize
        self.columns = columns
        self.onSelect = onSelect
    }

    public var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 12) {
            ForEach(AppIconChoice.allCases) { choice in
                Button { onSelect(choice) } label: {
                    AppIconTile(choice: choice, isSelected: choice == selection, size: iconSize)
                }
                .buttonStyle(.pressable)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct AppIconTile: View {
    let choice: AppIconChoice
    let isSelected: Bool
    let size: CGFloat

    var body: some View {
        VStack(spacing: 6) {
            preview
                .frame(width: size, height: size)
                .padding(3)
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: isSelected ? 2.5 : 0)
                )
            Text(choice.name)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(choice.name) icon")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private var preview: some View {
        if let url = choice.previewURL, let image = PlatformImage(contentsOfFile: url.path) {
            Image(platformImage: image)
                .resizable()
                .interpolation(.high)
        } else {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(.quaternary)
        }
    }
}
