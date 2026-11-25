import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// A `/btw` side question and its answer, above the message box. It isn't
/// part of the conversation: closing it lets it go for good.
public struct SideQuestionCard: View {
    @Environment(\.companionPalette) private var palette
    @Environment(\.dockCardStyle) private var style
    public let question: SideQuestion
    public let close: () -> Void
    @State private var contentHeight: CGFloat = 0
    @State private var copied = false

    /// Long answers scroll past this.
    private let maxHeight: CGFloat

    public init(question: SideQuestion, maxHeight: CGFloat = 320, close: @escaping () -> Void) {
        self.question = question
        self.maxHeight = maxHeight
        self.close = close
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .foregroundStyle(palette.accent)
                // The note goes when there's no room for all of it.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        title
                        Text("Not added to the conversation")
                            .font(style.caption)
                            .foregroundStyle(palette.inkMuted)
                            .fixedSize()
                    }
                    title
                }
                Spacer(minLength: 8)
                if question.state == .answered {
                    Button(action: copy) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(style.heading)
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                    .foregroundStyle(palette.inkMuted)
                    .help("Copy the answer")
                    .accessibilityLabel(copied ? "Copied" : "Copy the answer")
                }
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
                .accessibilityLabel("Close the side question")
            }
            Text(question.question)
                .font(style.body.weight(.medium))
                .foregroundStyle(palette.ink)
                .lineLimit(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            answer
                // The answer fades in as the card grows to hold it, rather
                // than the card jumping taller with it already there.
                .animation(.easeOut(duration: 0.18), value: showsAnswer)
        }
        .padding(14)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: style.radius ?? 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: style.radius ?? 20, style: .continuous)
            .strokeBorder(palette.accent.opacity(0.45), lineWidth: style.borderWidth ?? 1.5))
        .accessibilityElement(children: .contain)
    }

    private var title: some View {
        Text("Side question")
            .font(style.title)
            .foregroundStyle(palette.ink)
            .fixedSize()
    }

    /// The answer has started to arrive, or there's a problem to show.
    private var showsAnswer: Bool {
        !(question.state == .asking && question.answer.isEmpty)
    }

    @ViewBuilder
    private var answer: some View {
        switch question.state {
        case .failed:
            Label(question.problem ?? "The agent couldn't answer that.", systemImage: "exclamationmark.triangle")
                .font(style.body)
                .foregroundStyle(palette.inkMuted)
        case .asking where question.answer.isEmpty:
            HStack(spacing: 8) {
                ActivityMark(activity: .working, size: 13)
                Text("Answering")
                    .font(style.body)
                    .foregroundStyle(palette.inkMuted)
            }
            // Gone at once, so it never shows through the answer.
            .transition(.asymmetric(insertion: .opacity, removal: .identity))
        default:
            ScrollView {
                MarkdownText(text: question.answer)
                    .font(style.heading)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            // Only an answer too long for the card scrolls. Without this the
            // scroller flashes while the card is still growing to fit.
            .scrollIndicators(contentHeight > maxHeight ? .automatic : .hidden)
            .defaultScrollAnchor(question.state == .asking ? .bottom : .top)
            .frame(height: min(max(contentHeight, 1), maxHeight))
            .animation(ChatMotion.dock, value: contentHeight)
            .transition(.opacity)
        }
    }

    private func copy() {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(question.answer, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = question.answer
        #endif
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}
