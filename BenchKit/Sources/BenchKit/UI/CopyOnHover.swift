import SwiftUI

extension View {
    /// A copy button beside a message while the pointer is over it, when
    /// `enabled`. It sits at the message's bottom corner, where you finish
    /// reading, so a long reply doesn't need scrolling back up to copy.
    /// Only the Mac has a pointer, so on the phone this is the message as
    /// it was.
    @ViewBuilder
    func copyOnHover(_ text: String, side: HorizontalEdge, when enabled: Bool) -> some View {
        #if os(macOS)
        if enabled {
            modifier(CopyOnHover(text: text, side: side))
        } else {
            self
        }
        #else
        self
        #endif
    }
}

#if os(macOS)
import AppKit

private struct CopyOnHover: ViewModifier {
    @Environment(\.companionPalette) private var palette
    let text: String
    let side: HorizontalEdge
    @State private var hovering = false
    @State private var copied = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: side == .leading ? .bottomLeading : .bottomTrailing) {
                if hovering || copied {
                    Button(action: copy) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .medium))
                            .contentTransition(.symbolEffect(.replace))
                            .foregroundStyle(copied ? palette.accent : palette.inkMuted)
                            .frame(width: 24, height: 24)
                            .background(palette.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(palette.hairline))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                    .help(copied ? "Copied" : "Copy message")
                    .accessibilityLabel("Copy message")
                    // Just outside the message, in the margin.
                    .offset(x: side == .leading ? -32 : 32)
                    .transition(.opacity)
                }
            }
            // The pointer stays "over" the message on its way to the button.
            .padding(side == .leading ? .leading : .trailing, 40)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .padding(side == .leading ? .leading : .trailing, -40)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .animation(.easeOut(duration: 0.15), value: copied)
    }

    private func copy() {
        // The Markdown as written, and formatted text for apps that take it.
        MarkdownExport.copy(text)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            copied = false
        }
    }
}
#endif
