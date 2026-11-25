import SwiftUI

/// Messages grouped the way you read them: your prompt, Claude's words, and
/// the run of tools in between folded into one card.
///
/// Equatable so SwiftUI can tell an unchanged row from a changed one and
/// leave the unchanged ones alone when the conversation redraws.
public struct TranscriptTurn: Identifiable, Equatable {
    public enum Kind: Equatable {
        case user(TranscriptMessage)
        case assistant(TranscriptMessage)
        case image(TranscriptMessage)
        case steps([TranscriptMessage])
        case system(TranscriptMessage)
    }
    public let id: String
    public let kind: Kind
    /// For steps: each call's result, by its tool use id, when the
    /// transcript kept them.
    public var results: [String: TranscriptMessage] = [:]

    public init(id: String, kind: Kind, results: [String: TranscriptMessage] = [:]) {
        self.id = id
        self.kind = kind
        self.results = results
    }

    public static func group(_ messages: [TranscriptMessage]) -> [TranscriptTurn] {
        Perf.measure("group") { groupNow(messages) }
    }

    private static func groupNow(_ messages: [TranscriptMessage]) -> [TranscriptTurn] {
        var turns: [TranscriptTurn] = []
        var steps: [TranscriptMessage] = []
        var results: [String: TranscriptMessage] = [:]
        func flush() {
            if let first = steps.first { turns.append(TranscriptTurn(id: "steps-" + first.id, kind: .steps(steps), results: results)) }
            steps = []
            results = [:]
        }
        // Messages waiting in Claude Code's queue, oldest first.
        var queued: [TranscriptMessage] = []
        // The slash command last run, until what it printed turns up.
        var command: TranscriptMessage?
        for message in messages {
            switch message.queue {
            case .added?:
                queued.append(message)
                continue
            case .left?:
                let match = message.text.isEmpty ? queued.indices.first : queued.firstIndex { $0.text == message.text }
                if let match { queued.remove(at: match) }
                continue
            case .cleared?:
                queued.removeAll()
                continue
            case nil:
                break
            }
            if let call = message.resultOf {
                // Its call is in the run under way, or the last one shown.
                if steps.contains(where: { $0.toolUseID == call }) {
                    results[call] = message
                } else if let last = turns.lastIndex(where: { if case .steps = $0.kind { true } else { false } }) {
                    turns[last].results[call] = message
                }
                continue
            }
            if let printed = message.shell, printed.command.isEmpty {
                // What a command you ran printed: it belongs to the command,
                // the last one still waiting on its output.
                if let index = turns.lastIndex(where: { turn in
                    if case .user(let candidate) = turn.kind, let run = candidate.shell { return !run.isFinished }
                    return false
                }), case .user(var command) = turns[index].kind {
                    command.shell?.stdout = printed.stdout
                    command.shell?.stderr = printed.stderr
                    turns[index] = TranscriptTurn(id: turns[index].id, kind: .user(command), results: turns[index].results)
                }
                continue
            }
            if let run = message.command {
                // A command becomes a turn once it has printed something.
                // Most print nothing, or nothing the chat doesn't show already.
                guard let printed = run.output else {
                    command = message
                    continue
                }
                guard var ran = command, let name = ran.command?.name else { continue }
                // `/context` draws for the terminal first; its Markdown follows.
                if CommandRun.recordsMarkdown.contains(name), !run.isMarkdown { continue }
                command = nil
                ran.command?.output = printed
                ran.command?.isMarkdown = run.isMarkdown
                guard ran.command?.isShown == true else { continue }
                flush()
                turns.append(TranscriptTurn(id: ran.id, kind: .user(ran)))
                continue
            }
            switch message.role {
            case .tool:
                // A change to Claude's to-do list isn't a line in the
                // conversation: the checklist itself shows it.
                if !message.updatesChecklist { steps.append(message) }
            case .user: flush(); turns.append(TranscriptTurn(id: message.id, kind: .user(message)))
            case .image: flush(); turns.append(TranscriptTurn(id: message.id, kind: .image(message)))
            case .assistant: flush(); turns.append(TranscriptTurn(id: message.id, kind: .assistant(message)))
            case .system: flush(); turns.append(TranscriptTurn(id: message.id, kind: .system(message)))
            }
        }
        flush()
        // Still waiting, so they go after everything Claude has done.
        turns += queued.map { TranscriptTurn(id: "queued-" + $0.id, kind: .user($0)) }
        return turns
    }

    /// True for a message you sent that's waiting for Claude to finish its
    /// step. `group` puts these last.
    public var isQueued: Bool {
        if case .user(let message) = kind { message.queue == .added } else { false }
    }
}

/// One turn of the conversation, drawn in the palette and the
/// `ChatTurnStyle` from the environment. The Mac and the iPhone both use
/// it; what differs between them is in the style.
public struct TranscriptTurnView: View {
    @Environment(\.companionPalette) private var palette
    @Environment(\.chatTurnStyle) private var style
    public let turn: TranscriptTurn
    /// True for the last turn while Claude is working on it.
    public var isLive: Bool

    public init(turn: TranscriptTurn, isLive: Bool = false) {
        self.turn = turn
        self.isLive = isLive
    }

    public var body: some View {
        switch turn.kind {
        case .user(let message) where message.shell != nil && !turn.isQueued:
            // A command you ran with `!`, and what it printed.
            ShellRunCard(run: message.shell!)
                .padding(.leading, style.indent)
        case .user(let message) where message.command != nil:
            // A slash command you ran, and what it printed.
            CommandRunCard(run: message.command!)
                .padding(.leading, style.indent)
        case .user(let message):
            let queued = turn.isQueued
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(message.images) { picture in
                    TranscriptImageView(image: picture, maxHeight: 260)
                }
                if !message.text.isEmpty {
                    // Markdown, so lists you typed read as lists. Links
                    // and code keep the bubble's ink, which they'd clash with.
                    MarkdownText(text: message.text, inheritsColor: true, ink: userInk(queued: queued))
                        .font(style.bodyFont)
                        .lineSpacing(style.lineSpacing)
                        .foregroundStyle(userInk(queued: queued))
                        .padding(.horizontal, 14)
                        .padding(.vertical, style.userBubblePadding)
                        .background(userFill(queued: queued), in: bubble)
                        .overlay {
                            // Waiting its turn: a dashed outline, not yet a sent bubble.
                            if queued { bubble.strokeBorder(queuedStroke, style: queuedDash) }
                        }
                        .copyOnHover(message.text, side: .leading, when: style.copyOnHover)
                }
                if queued {
                    QueuedCaption(turn: turn, font: style.smallFont)
                }
            }
            .queuedMenu(turn)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, style.userInset)
        case .image(let message):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(message.images) { picture in
                    TranscriptImageView(image: picture, maxHeight: 320)
                }
                Text(message.text)
                    .font(style.smallFont)
                    .foregroundStyle(palette.inkMuted)
            }
            .padding(.leading, style.indent)
        case .assistant(let message):
            HStack(alignment: .top, spacing: style.mark.spacing) {
                ClaudeMark(size: style.mark.size, width: style.mark.width)
                    .padding(.top, style.mark.topPadding)
                MarkdownText(text: message.text)
                    .font(style.bodyFont)
                    .lineSpacing(style.lineSpacing)
                    .foregroundStyle(palette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .copyOnHover(message.text, side: .trailing, when: style.copyOnHover)
        case .steps(let steps):
            StepRunView(steps: steps, results: turn.results, isLive: isLive)
                .padding(.leading, style.indent)
        case .system(let message) where message.notice != nil:
            TaskNoticeRow(message: message)
                .padding(.leading, style.noticeIndent)
        case .system(let message) where message.worked != nil:
            TurnTimeRow(message: message)
                .padding(.leading, style.indent)
        case .system(let message):
            systemRow(message)
        }
    }

    // MARK: Your messages

    private var bubble: UnevenRoundedRectangle {
        switch style.userBubble {
        case .tail(let radius, let tailRadius):
            UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: radius, bottomTrailingRadius: tailRadius,
                                   topTrailingRadius: radius, style: .continuous)
        case .accent(let radius):
            UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: radius, bottomTrailingRadius: radius,
                                   topTrailingRadius: radius, style: .continuous)
        }
    }

    private func userInk(queued: Bool) -> Color {
        switch style.userBubble {
        case .tail: queued ? palette.inkMuted : palette.ink
        case .accent: queued ? palette.ink : palette.onAccent
        }
    }

    private func userFill(queued: Bool) -> AnyShapeStyle {
        switch style.userBubble {
        case .tail:
            AnyShapeStyle(palette.accent.opacity(queued ? 0.07 : 0.16))
        case .accent:
            queued
                ? AnyShapeStyle(palette.accent.opacity(0.12))
                : AnyShapeStyle(LinearGradient(colors: [palette.accent, palette.accent.opacity(0.82)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing))
        }
    }

    private var queuedStroke: Color {
        switch style.userBubble {
        case .tail: palette.inkMuted.opacity(0.5)
        case .accent: palette.accent.opacity(0.7)
        }
    }

    private var queuedDash: StrokeStyle {
        switch style.userBubble {
        case .tail: StrokeStyle(lineWidth: 1, dash: [4, 3])
        case .accent: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
        }
    }

    // MARK: Notes from Claude Code

    private static let systemSymbol = "arrow.down.right.and.arrow.up.left"

    private func systemRow(_ message: TranscriptMessage) -> some View {
        let row = style.systemRow
        let shape = RoundedRectangle(cornerRadius: row.radius, style: .continuous)
        return Group {
            if row.centered {
                VStack(spacing: 3) {
                    Label(message.text, systemImage: Self.systemSymbol)
                        .font(row.titleFont)
                        .foregroundStyle(palette.ink)
                    if let detail = message.detail {
                        Text(detail)
                            .font(row.detailFont)
                            .foregroundStyle(palette.inkMuted)
                            .multilineTextAlignment(.center)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: Self.systemSymbol)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(message.text).font(row.titleFont).foregroundStyle(palette.ink)
                        if let detail = message.detail {
                            Text(detail)
                        }
                    }
                }
                .font(row.detailFont)
                .foregroundStyle(palette.inkMuted)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(row.fill == .raised ? palette.raised : palette.surface, in: shape)
        .overlay {
            if row.stroked { shape.strokeBorder(palette.hairline) }
        }
        .padding(.vertical, 4)
    }
}

/// Compared by what it shows, so a redraw of the chat (the session's state
/// refreshes twice a second while Claude works) leaves rows that haven't
/// changed alone.
extension TranscriptTurnView: Equatable {
    public nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.isLive == rhs.isLive && lhs.turn == rhs.turn
    }
}

/// Claude's ✻, in its orange.
public struct ClaudeMark: View {
    @Environment(\.companionPalette) private var palette
    /// Drawn at this size, rather than scaled up, so it stays sharp.
    public var size: CGFloat
    /// The column it sits in, a little wider than the glyph.
    public var width: CGFloat

    public init(size: CGFloat = 14, width: CGFloat? = nil) {
        self.size = size
        self.width = width ?? size + 2
    }

    public var body: some View {
        Text("✻\u{FE0E}")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(palette.accent)
            .frame(width: width)
            .accessibilityHidden(true)
    }
}

/// A picture from the conversation, sized to the column. Tap or click for
/// the whole thing.
///
/// Decoding happens off the main thread; until it's done, a picture whose
/// size is known holds its place so the conversation doesn't jump.
public struct TranscriptImageView: View {
    @Environment(\.companionPalette) private var palette
    public let image: TranscriptImage
    public var maxHeight: CGFloat = 320
    @State private var showsFull = false
    @State private var decoded: PlatformImage?

    public init(image: TranscriptImage, maxHeight: CGFloat = 320) {
        self.image = image
        self.maxHeight = maxHeight
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 14, style: .continuous) }

    @Environment(\.showPicture) private var showPicture
    @Environment(\.loadFullImage) private var loadFull

    private func openFull(_ picture: PlatformImage) {
        // Over the whole window when the window offers it, as on the Mac,
        // since a sheet there stays small.
        if let showPicture {
            showPicture(ShownPicture(image: image, preview: picture, loadFull: loadFull))
        } else {
            showsFull = true
        }
    }

    /// The whole picture, read in when the conversation only holds a preview.
    private func wholeImage() async -> TranscriptImage {
        guard image.isPreview, let loadFull, let whole = await loadFull(image) else { return image }
        return whole
    }

    public var body: some View {
        if let picture = decoded ?? ImageCache.shared.cached(image) {
            let view = Image(platformImage: picture)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: maxHeight)
                .clipShape(shape)
                .overlay(shape.strokeBorder(palette.hairline))
                .contentShape(shape)
                .onTapGesture { openFull(picture) }
                // Pinching a picture in the conversation opens it to zoom.
                .simultaneousGesture(MagnifyGesture().onChanged { value in
                    if value.magnification > 1.08, !showsFull { openFull(picture) }
                })
            #if os(iOS)
            view.fullScreenCover(isPresented: $showsFull) { ImageViewer(image: image, preview: picture) }
            #else
            view
                .contextMenu {
                    Button("Copy Image") { Task { PictureExport.copy(await wholeImage()) } }
                    Button("Save Image\u{2026}") { Task { PictureExport.save(await wholeImage()) } }
                }
                .sheet(isPresented: $showsFull) { ImageViewer(image: image, preview: picture).frame(minWidth: 900, minHeight: 640) }
            #endif
        } else if let ratio = image.aspectRatio {
            shape.fill(palette.raised)
                .aspectRatio(ratio, contentMode: .fit)
                .frame(maxHeight: maxHeight)
                .overlay(shape.strokeBorder(palette.hairline))
                .task(id: image.id) { decoded = await ImageCache.shared.load(image) }
        } else {
            // No size to hold: nothing until it's decoded, a moment later.
            Color.clear.frame(width: 0, height: 0)
                .task(id: image.id) { decoded = await ImageCache.shared.load(image) }
        }
    }
}

/// A picture from the conversation, opened to look at closely.
public struct ShownPicture: Identifiable {
    public var id: String { image.id }
    let image: TranscriptImage
    let preview: PlatformImage
    let loadFull: (@Sendable (TranscriptImage) async -> TranscriptImage?)?
}

extension EnvironmentValues {
    /// Opens a picture over the whole window. Set at the root of a window
    /// that shows `PictureViewer` in an overlay; without it, a picture
    /// opens in a sheet or cover of its own.
    @Entry public var showPicture: ((ShownPicture) -> Void)?
}

/// The viewer for a `ShownPicture`, to lay over a whole window.
public struct PictureViewer: View {
    let shown: ShownPicture
    let onClose: () -> Void

    public init(_ shown: ShownPicture, onClose: @escaping () -> Void) {
        self.shown = shown
        self.onClose = onClose
    }

    public var body: some View {
        ImageViewer(image: shown.image, preview: shown.preview, onClose: onClose)
            .environment(\.loadFullImage, shown.loadFull)
    }
}

/// The picture on its own, on black, with pinch to zoom. A picture that
/// came as a preview opens as the preview, and the whole picture takes
/// its place once the Mac has sent it.
private struct ImageViewer: View {
    let image: TranscriptImage
    let preview: PlatformImage
    /// Set when the viewer sits over a Mac window rather than in a cover.
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.loadFullImage) private var loadFull
    @Environment(CompanionClient.self) private var client: CompanionClient?
    /// The whole picture read through `loadFull`, once it has been.
    @State private var loaded: PlatformImage?

    private var picture: PlatformImage {
        if let loaded { return loaded }
        guard image.isPreview, let full = client?.fullImages[image.id],
              let decoded = ImageCache.shared.image(for: full) else { return preview }
        return decoded
    }

    private var isLoadingFull: Bool {
        guard image.isPreview else { return false }
        if loadFull != nil { return loaded == nil }
        return client?.fullImages[image.id] == nil && client?.status == .connected
            && client?.macFeatures.contains(CompanionFeature.imagePreviews) == true
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Flips on as the viewer opens, to ease the picture in.
    @State private var appeared = false
    @State private var showsHint = false
    @State private var closeHovered = false
    @State private var closing = false
    @FocusState private var focused: Bool

    private func close() {
        guard let onClose else { return dismiss() }
        guard !closing else { return }
        closing = true
        withAnimation(.smooth(duration: 0.22)) { appeared = false }
        Task {
            try? await Task.sleep(for: .seconds(0.22))
            onClose()
        }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Not flat black: a faint lift in the middle, darkening to the edges.
            RadialGradient(colors: [Color(white: 0.15), .black], center: .center, startRadius: 0, endRadius: 900)
                .ignoresSafeArea()
            zoomingImage
                .ignoresSafeArea()
                .opacity(appeared ? 1 : 0)
                .scaleEffect(appeared || reduceMotion ? 1 : 0.96)
            HStack(spacing: 10) {
                if isLoadingFull {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                        .frame(width: 40, height: 40)
                        .benchGlass(in: .circle)
                        .transition(.opacity)
                        .accessibilityLabel("Loading the whole picture")
                }
                closeButton
            }
            .padding(16)
            .opacity(appeared ? 1 : 0)
        }
        .opacity(onClose == nil || appeared ? 1 : 0)
        .overlay(alignment: .bottom) { hint }
        .animation(.smooth(duration: 0.25), value: isLoadingFull)
        // Over a window, take the keyboard from whatever is behind, so
        // Escape closes the picture and typing doesn't land in a terminal.
        .focusable(onClose != nil)
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.escape) {
            close()
            return .handled
        }
        .onAppear {
            if onClose != nil { focused = true }
            withAnimation(.smooth(duration: 0.35)) { appeared = true }
        }
        #if os(macOS)
        .task {
            // A quiet reminder that the picture zooms, gone after a moment.
            try? await Task.sleep(for: .seconds(0.4))
            withAnimation(.smooth(duration: 0.3)) { showsHint = true }
            try? await Task.sleep(for: .seconds(2.4))
            withAnimation(.smooth(duration: 0.5)) { showsHint = false }
        }
        #endif
        .task {
            if let loadFull {
                guard image.isPreview, let whole = await loadFull(image) else { return }
                loaded = await ImageCache.shared.load(whole)
            } else {
                client?.requestImage(image)
            }
        }
    }

    @ViewBuilder private var zoomingImage: some View {
        #if os(macOS)
        ZoomingImage(
            picture: picture,
            onCopy: { Task { PictureExport.copy(await wholeImage()) } },
            onSave: { Task { PictureExport.save(await wholeImage()) } },
            onClose: { close() }
        )
        #else
        ZoomingImage(picture: picture, onClose: { close() })
        #endif
    }

    /// The whole picture for copying or saving, read in when only a preview is here.
    private func wholeImage() async -> TranscriptImage {
        guard image.isPreview else { return image }
        if let loadFull { return await loadFull(image) ?? image }
        return client?.fullImages[image.id] ?? image
    }

    private var closeButton: some View {
            Button {
                close()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white.opacity(closeHovered ? 1 : 0.85))
                    .frame(width: 40, height: 40)
                    .benchGlass(in: .circle, interactive: true)
                    .scaleEffect(closeHovered && !reduceMotion ? 1.08 : 1)
            }
            .buttonStyle(.pressable)
            .keyboardShortcut(.cancelAction)
            .onHover { hovering in withAnimation(.snappy(duration: 0.18)) { closeHovered = hovering } }
            .accessibilityLabel("Close")
    }

    @ViewBuilder private var hint: some View {
        if showsHint {
            Text("Pinch or double-click to zoom")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .benchGlass(in: .capsule)
                .padding(.bottom, 20)
                .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : 6)))
                .allowsHitTesting(false)
        }
    }
}

#if os(iOS)
import UIKit

/// The picture in UIKit's zooming scroll view, which zooms around your
/// fingers and pans while zoomed, as in Photos. Double-tap zooms in on
/// the spot you tapped, or back out.
private struct ZoomingImage: UIViewRepresentable {
    let picture: UIImage
    let onClose: () -> Void

    func makeUIView(context: Context) -> ZoomingImageView {
        ZoomingImageView(picture: picture)
    }

    func updateUIView(_ view: ZoomingImageView, context: Context) {
        view.show(picture)
        view.onClose = onClose
    }
}

final class ZoomingImageView: UIScrollView, UIScrollViewDelegate {
    private let imageView: UIImageView
    private var laidOutSize: CGSize = .zero
    var onClose: (() -> Void)?

    init(picture: UIImage) {
        imageView = UIImageView(image: picture)
        super.init(frame: .zero)
        delegate = self
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        backgroundColor = .clear
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    /// Swaps the picture, as when the whole one arrives after its preview,
    /// keeping the fit since both have the same shape.
    func show(_ picture: UIImage) {
        guard imageView.image !== picture else { return }
        imageView.image = picture
        laidOutSize = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Fit the picture to the screen at zoom 1, again whenever the screen turns.
        if bounds.size != laidOutSize, let image = imageView.image, image.size.width > 0, image.size.height > 0 {
            laidOutSize = bounds.size
            zoomScale = 1
            let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
            imageView.frame = CGRect(origin: .zero, size: CGSize(width: image.size.width * fit, height: image.size.height * fit))
            contentSize = imageView.frame.size
            // Enough to see the picture's own pixels, and never less than 4x.
            minimumZoomScale = 1
            maximumZoomScale = max(4, 2 / fit)
        }
        center()
    }

    /// Keeps the picture in the middle while it's smaller than the screen.
    private func center() {
        let x = max(0, (bounds.width - contentSize.width) / 2)
        let y = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { center() }

    /// A tap on the backdrop around the picture closes the viewer.
    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        guard !imageView.bounds.contains(tap.location(in: imageView)) else { return }
        onClose?()
    }

    @objc private func doubleTapped(_ tap: UITapGestureRecognizer) {
        // The backdrop's first tap already closed the viewer.
        guard imageView.bounds.contains(tap.location(in: imageView)) else { return }
        if zoomScale > minimumZoomScale {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            let point = tap.location(in: imageView)
            let scale = min(maximumZoomScale, 3)
            let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }
}
#endif

#if os(macOS)
import AppKit
import UniformTypeIdentifiers

/// Copying and saving a picture from the conversation, from its menu.
@MainActor
enum PictureExport {
    private static func type(of image: TranscriptImage) -> UTType {
        UTType(mimeType: image.mediaType) ?? .png
    }

    /// Puts the picture's own bytes on the clipboard, plus a TIFF for apps
    /// that only take that.
    static func copy(_ image: TranscriptImage) {
        let item = NSPasteboardItem()
        item.setData(image.data, forType: NSPasteboard.PasteboardType(type(of: image).identifier))
        if let tiff = NSImage(data: image.data)?.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    /// Asks where to save the picture, then writes it there as it came.
    static func save(_ image: TranscriptImage) {
        let type = type(of: image)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Image." + (type.preferredFilenameExtension ?? "png")
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        let data = image.data
        let write: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: write)
        } else {
            panel.begin(completionHandler: write)
        }
    }
}

/// The picture in AppKit's magnifying scroll view: a trackpad pinch zooms
/// around the pointer and scrolling pans while zoomed. Double-click (or
/// a two-finger double-tap) zooms in on that spot, or back out.
private struct ZoomingImage: NSViewRepresentable {
    let picture: NSImage
    let onCopy: () -> Void
    let onSave: () -> Void
    let onClose: () -> Void

    func makeNSView(context: Context) -> ZoomingImageView {
        ZoomingImageView(picture: picture)
    }

    func updateNSView(_ view: ZoomingImageView, context: Context) {
        view.show(picture)
        view.onCopy = onCopy
        view.onSave = onSave
        view.onClose = onClose
    }
}

final class ZoomingImageView: NSScrollView {
    private let imageView = NSImageView()
    /// Holds the picture and casts its shadow, since the picture's own
    /// layer clips to its rounded corners.
    private let frameView = NSView()
    private var laidOutSize: NSSize = .zero
    /// Room left around the picture at zoom 1, so it floats on the backdrop.
    private let margin: CGFloat = 28

    init(picture: NSImage) {
        super.init(frame: .zero)
        contentView = CenteringClipView()
        contentView.drawsBackground = false
        drawsBackground = false
        hasVerticalScroller = false
        hasHorizontalScroller = false
        allowsMagnification = true
        minMagnification = 1
        imageView.image = picture
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.isEditable = false
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 10
        imageView.layer?.cornerCurve = .continuous
        imageView.layer?.masksToBounds = true
        imageView.autoresizingMask = [.width, .height]
        frameView.wantsLayer = true
        frameView.shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
            shadow.shadowBlurRadius = 28
            shadow.shadowOffset = NSSize(width: 0, height: -10)
            return shadow
        }()
        frameView.addSubview(imageView)
        documentView = frameView
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(doubleClicked))
        doubleClick.numberOfClicksRequired = 2
        addGestureRecognizer(doubleClick)
        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked))
        click.numberOfClicksRequired = 1
        addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    /// Swaps the picture, as when the whole one arrives after its preview,
    /// keeping the zoom since both have the same shape.
    func show(_ picture: NSImage) {
        guard imageView.image !== picture else { return }
        imageView.image = picture
    }

    override func layout() {
        super.layout()
        // Fit the picture to the view at zoom 1, again whenever it resizes.
        let room = contentSize
        guard room != laidOutSize, room.width > 0, room.height > 0,
              let image = imageView.image, image.size.width > 0, image.size.height > 0 else { return }
        laidOutSize = room
        magnification = 1
        let inset = min(margin, room.width / 8, room.height / 8)
        let fit = min((room.width - inset * 2) / image.size.width, (room.height - inset * 2) / image.size.height)
        frameView.frame = NSRect(origin: .zero, size: NSSize(width: image.size.width * fit, height: image.size.height * fit))
        imageView.frame = frameView.bounds
        // Enough to see the picture's own pixels, and never less than 4x.
        maxMagnification = max(4, 2 / fit)
    }

    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onClose: (() -> Void)?

    /// Copy and Save on a right-click, as on the picture in the conversation.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let copy = NSMenuItem(title: "Copy Image", action: #selector(copyPicture), keyEquivalent: "")
        let save = NSMenuItem(title: "Save Image\u{2026}", action: #selector(savePicture), keyEquivalent: "")
        for item in [copy, save] {
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc private func copyPicture() { onCopy?() }
    @objc private func savePicture() { onSave?() }

    /// A click on the backdrop around the picture closes the viewer.
    @objc private func clicked(_ click: NSClickGestureRecognizer) {
        guard !frameView.bounds.contains(click.location(in: frameView)) else { return }
        onClose?()
    }

    @objc private func doubleClicked(_ click: NSClickGestureRecognizer) {
        // The backdrop's first click already closed the viewer.
        guard frameView.bounds.contains(click.location(in: frameView)) else { return }
        let target: CGFloat = magnification > minMagnification + 0.01 ? minMagnification : min(maxMagnification, 3)
        let point = click.location(in: frameView)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            animator().setMagnification(target, centeredAt: point)
        }
    }
}

/// Keeps the picture in the middle while it's smaller than the view.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
        if rect.height > document.frame.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        return rect
    }
}
#endif

extension TranscriptMessage {
    /// True for a call that only edits or reads Claude's to-do list.
    var updatesChecklist: Bool {
        role == .tool && tool == .checklist
    }
}
