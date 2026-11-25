import Foundation
import SwiftUI

/// Keeps a chat's scroll view on its newest content, the way messaging apps do.
///
/// While you're at the bottom, it stays there as the conversation grows,
/// including while the last turn grows in place (streamed text, new tool
/// steps) and when the view gets shorter (a permission card, the keyboard).
/// Scroll up to read and it leaves you there, with a button to jump back.
/// Sending a message brings you back to the bottom.
///
/// This leans on the list's heights being real. The chat views draw the
/// newest turns in a plain stack (see `ChatTail`) and the history above them
/// in chunks that are only drawn near the screen, and keep their measured
/// height when they aren't (see `ChatHistory`). A lazy stack guesses its
/// height instead, and the bottom of a guess can be over nothing at all.
struct StickToBottom<Key: Equatable>: ViewModifier {
    /// Changes when you send something, which always scrolls down.
    let sentKey: Key

    @Environment(\.companionPalette) private var palette
    @Environment(\.chatTimingID) private var timingID
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var pinned = true
    /// True while your finger is on the list or it's coasting from a flick.
    @State private var touching = false
    /// True once the list has had a size, for the timing mark.
    @State private var laidOut = false
    /// A bottom margin flicked to 1 and back right after opening; see `resync()`.
    @State private var resyncMargin: CGFloat = 0
    /// The latest size, kept out of the view's state since it changes on
    /// every scrolled frame and nothing on screen draws from it.
    @State private var latest = Latest()
    /// The re-sync under way, so a new one replaces it rather than stacking.
    @State private var resyncTask: Task<Void, Never>?

    /// How close to the bottom still counts as at the bottom.
    private let slack: CGFloat = 40

    private struct Metrics: Equatable {
        var contentHeight: CGFloat
        var viewHeight: CGFloat
        var fromBottom: CGFloat
    }

    private final class Latest {
        var metrics: Metrics?
    }

    func body(content: Content) -> some View {
        content
            .environment(\.chatHistoryShift, ChatHistoryShift { delta in
                // History above the screen changed height. The scroll view
                // keeps its distance from the top, so what you were reading
                // would move by that much: move with it. At the bottom,
                // following the bottom already takes care of it.
                guard !pinned, let metrics = latest.metrics else { return }
                position.scrollTo(y: max(0, metrics.contentHeight - metrics.viewHeight - metrics.fromBottom + delta))
            })
            .contentMargins(.bottom, resyncMargin, for: .scrollContent)
            .scrollPosition($position)
            .defaultScrollAnchor(.bottom)
            .onScrollGeometryChange(for: Metrics.self) { geo in
                // Measured from what's visible, which takes in the edges
                // under bars and the message box. On iPhone the container
                // size leaves those out, so it can't be used for this.
                Metrics(contentHeight: geo.contentSize.height, viewHeight: geo.containerSize.height,
                        fromBottom: geo.contentSize.height + geo.contentInsets.bottom - geo.visibleRect.maxY)
            } action: { old, new in
                // Not laid out yet, as while the screen slides in.
                guard new.viewHeight > 0, new.contentHeight > 0 else { return }
                latest.metrics = new
                #if DEBUG
                ChatDebug.scrollState = "content=\(Int(new.contentHeight)) view=\(Int(new.viewHeight)) fromBottom=\(Int(new.fromBottom)) pinned=\(pinned)"
                #endif
                if !laidOut {
                    laidOut = true
                    Perf.mark("firstLayout")
                    resync()
                    if let timingID {
                        ChatTiming.note("list laid out", tab: timingID,
                                        details: "content=\(Int(new.contentHeight)) view=\(Int(new.viewHeight))", once: true)
                    }
                }
                if new.contentHeight != old.contentHeight || new.viewHeight != old.viewHeight {
                    // The content or the view changed size, not you: keep
                    // following if you were following.
                    // While you're scrolling, rows coming into view can
                    // change the height too; pulling you down then fights
                    // your scroll, so your position decides instead.
                    if pinned && !touching {
                        // New rows grow in (see ChatMotion), so following
                        // them frame by frame is what makes the glide.
                        position.scrollTo(edge: .bottom)
                    } else {
                        setPinned(new.fromBottom <= slack)
                    }
                } else {
                    #if os(iOS)
                    // Only your own scrolling lets go of the bottom. The list
                    // can jump on its own as it lays out, and that shouldn't.
                    if touching { setPinned(new.fromBottom <= slack) } else if pinned { position.scrollTo(edge: .bottom) }
                    #else
                    setPinned(new.fromBottom <= slack)
                    #endif
                }
            }
            #if DEBUG
            // BENCH_CHAT_SCROLL_UP=<points> scrolls a test copy's chat up
            // from the bottom a few seconds in, for screenshots of what
            // sits under the message box.
            .task {
                guard let up = ProcessInfo.processInfo.environment["BENCH_CHAT_SCROLL_UP"].flatMap(Double.init) else { return }
                try? await Task.sleep(for: .seconds(5))
                guard let metrics = latest.metrics else { return }
                pinned = false
                position.scrollTo(y: max(0, metrics.contentHeight - metrics.viewHeight - up))
            }
            #endif
            .onScrollPhaseChange { _, phase in
                let now = phase == .tracking || phase == .interacting || phase == .decelerating
                if now != touching { touching = now }
            }
            .onChange(of: sentKey) { _, _ in
                // No animated scroll here. Already at the bottom, the new
                // row's own arrival makes the glide (see above). Scrolled
                // up, an animated scroll runs through rows the lazy list
                // has only guessed the heights of, and on the Mac that
                // can leave it showing nothing at all. Jump instead.
                pinned = true
                position.scrollTo(edge: .bottom)
                resync()
            }
            .overlay(alignment: .bottom) {
                if !pinned {
                    Button {
                        pinned = true
                        withAnimation(.easeOut(duration: 0.3)) { position.scrollTo(edge: .bottom) }
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(palette.ink)
                            .frame(width: 32, height: 32)
                            #if os(macOS)
                            // Glass on the Mac, floating with the message box.
                            .benchGlass(in: .circle, interactive: true)
                            #else
                            .background(Circle().fill(palette.surface).shadow(color: .black.opacity(0.12), radius: 6, y: 2))
                            .overlay(Circle().strokeBorder(palette.hairline))
                            #endif
                            .contentShape(Circle())
                    }
                    .buttonStyle(.pressable)
                    .accessibilityLabel("Jump to latest")
                    .padding(.bottom, 10)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.2), value: pinned)
    }

    /// On the Mac, a long chat can open blank. The scroll view AppKit draws
    /// keeps the history's first height guess (tens of thousands of points too
    /// tall for a long chat) and sits at the bottom of that, below every row,
    /// while SwiftUI reports the real height and thinks all is well. AppKit
    /// only takes the real height when the content changes size, which
    /// otherwise waits for Claude's next output. Changing a bottom margin by
    /// a point, and back, is such a change, done twice as the rows settle.
    ///
    /// The same can happen later: sending a message, or the conversation
    /// jumping in height all at once, so it's done then too.
    private func resync() {
        #if os(macOS)
        resyncTask?.cancel()
        resyncTask = Task { @MainActor in
            for delay in [150, 600] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled else { return }
                resyncMargin = 1
                try? await Task.sleep(for: .milliseconds(50))
                resyncMargin = 0
                if pinned { position.scrollTo(edge: .bottom) }
            }
        }
        #endif
    }

    /// Scroll geometry changes every frame, so only a real change is written.
    private func setPinned(_ value: Bool) {
        if pinned != value { pinned = value }
    }
}

#if DEBUG
/// Where the chat's scroll view last was, for the load-test layout dump.
@MainActor public enum ChatDebug {
    public static var scrollState = ""
}
#endif

public extension EnvironmentValues {
    /// The tab to note this chat's timing under, where it's being timed.
    @Entry var chatTimingID: UUID?
}

public extension View {
    /// Keeps this chat scroll view on its newest content while you're at the
    /// bottom. `sentKey` should change when you send a message.
    func sticksToBottom<Key: Equatable>(sentKey: Key) -> some View {
        modifier(StickToBottom(sentKey: sentKey))
    }
}

/// Where a chat's newest turns begin: the ones drawn in a plain stack, below
/// a lazy one holding the history (see the chat views).
public enum ChatTail {
    /// The fewest turns kept in the plain stack. Enough to more than fill
    /// the window, so the lazy stack is off screen while you're at the bottom.
    static let least = 10
    /// How many turns arrive before the older ones move up into the history.
    /// Moving them rebuilds their rows, so it's done in batches, and only
    /// as a new turn arrives, which is nearly always you sending a message
    /// and the chat going to the bottom.
    static let batch = 15

    /// The index of the first of the newest turns, out of `count`. Short
    /// conversations are all plain: nothing in them is lazy.
    public static func start(count: Int) -> Int {
        max(0, (count - least) / batch * batch)
    }

    /// The history's turns, split into the chunks it's drawn in. The split
    /// counts from the start, and the history grows a whole batch at a
    /// time, so a chunk holds the same turns for as long as the chat lasts.
    public static func chunks(of count: Int) -> [Range<Int>] {
        stride(from: 0, to: count, by: batch).map { $0..<min($0 + batch, count) }
    }

    /// How close a chunk of history is to what's on screen.
    public enum Reach: Equatable, Sendable { case near, between, far }

    /// A chunk is drawn once it's within this far of the screen: more than
    /// a window's height, so it's there before you reach it.
    static let drawWithin: CGFloat = 1500
    /// And dropped once it's this far away. Well past `drawWithin`, so
    /// scrolling back and forth near one line doesn't draw and drop it.
    static let dropBeyond: CGFloat = 4000

    /// All four edges are measured down the list from the same point.
    public static func reach(top: CGFloat, bottom: CGFloat, screenTop: CGFloat, screenBottom: CGFloat) -> Reach {
        let gap = max(screenTop - bottom, top - screenBottom, 0)
        return gap < drawWithin ? .near : gap > dropBeyond ? .far : .between
    }

    /// A height for a chunk that hasn't been drawn yet. Only the scroll bar
    /// shows it, so it needs to be plausible, not right.
    static func roughHeight(turns: Int, spacing: CGFloat) -> CGFloat {
        CGFloat(turns) * 300 + CGFloat(max(0, turns - 1)) * spacing
    }
}

/// The history above a chat's newest turns, drawn a chunk of turns at a
/// time: only the chunks near the screen, with an empty space standing in
/// for each of the others.
///
/// This used to be a lazy stack, whose height is a guess that moves with
/// which rows it has drawn. Above the newest turns, in a chat following the
/// bottom, that made a loop: the guess changed, the list moved to stay at
/// the bottom, a different row at the stack's end was drawn, and the guess
/// changed back. The conversation jumped thousands of points a frame, drew
/// old rows over new ones, and came to rest away from the bottom.
///
/// A chunk has no guess to move. It's a plain stack while it's drawn, and
/// when it's dropped its space keeps the height it measured. A chunk that
/// has never been drawn takes a rough height until it is, which happens
/// well before it reaches the screen.
public struct ChatHistory<Row: View>: View {
    private let turns: ArraySlice<TranscriptTurn>
    private let spacing: CGFloat
    private let row: (TranscriptTurn) -> Row
    /// How many turns the history held when the chat opened.
    @State private var turnsAtFirst: Int

    /// Keep this in the list even while `turns` is empty (it draws nothing
    /// then), so it knows which chunks arrived after the chat opened.
    public init(_ turns: ArraySlice<TranscriptTurn>, spacing: CGFloat, @ViewBuilder row: @escaping (TranscriptTurn) -> Row) {
        self.turns = turns
        self.spacing = spacing
        self.row = row
        _turnsAtFirst = State(initialValue: turns.count)
    }

    public var body: some View {
        if !turns.isEmpty {
            VStack(alignment: .leading, spacing: spacing) {
                ForEach(ChatTail.chunks(of: turns.count), id: \.lowerBound) { range in
                    let chunk = turns[(turns.startIndex + range.lowerBound)..<(turns.startIndex + range.upperBound)]
                    // A chunk that arrives while the chat is open holds
                    // turns that were among the newest a moment ago, maybe
                    // on screen. It starts out drawn, so they stay put.
                    // Named for its first turn, so a chunk keeps its height
                    // as long as it holds the same turns.
                    Chunk(turns: chunk, spacing: spacing, row: row, startsDrawn: range.lowerBound >= turnsAtFirst)
                        .id(chunk.first?.id)
                }
            }
        }
    }

    private struct Chunk: View {
        let turns: ArraySlice<TranscriptTurn>
        let spacing: CGFloat
        let row: (TranscriptTurn) -> Row
        @State private var stage: Stage
        @State private var memo = Memo()

        init(turns: ArraySlice<TranscriptTurn>, spacing: CGFloat, row: @escaping (TranscriptTurn) -> Row, startsDrawn: Bool) {
            self.turns = turns
            self.spacing = spacing
            self.row = row
            _stage = State(initialValue: startsDrawn ? .drawn : .space)
        }
        @Environment(\.chatHistoryShift) private var shift

        /// A chunk is an empty space until it nears the screen. The first
        /// time, its rows are measured out of sight on top of that space,
        /// so the space can turn into them and the scroll view can move by
        /// the difference in the same step. Changing height first and
        /// moving a frame later showed the wrong part of the chat between.
        private enum Stage { case space, measuring, drawn }

        /// The chunk's height, and whether all of it is above the screen.
        private struct Extent: Equatable {
            var height: CGFloat
            var isAbove: Bool
        }

        private var space: CGFloat {
            memo.height ?? ChatTail.roughHeight(turns: turns.count, spacing: spacing)
        }

        private var rows: some View {
            VStack(alignment: .leading, spacing: spacing) {
                ForEach(turns) { row($0) }
            }
        }

        var body: some View {
            Group {
                switch stage {
                case .space:
                    Color.clear.frame(height: space)
                case .measuring:
                    Color.clear.frame(height: space)
                        .overlay(alignment: .top) {
                            rows.fixedSize(horizontal: false, vertical: true).hidden()
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measured($0) }
                        }
                case .drawn:
                    rows
                }
            }
            .onGeometryChange(for: Extent.self) { proxy in
                Extent(height: proxy.size.height,
                       isAbove: proxy.bounds(of: .scrollView).map { $0.minY >= proxy.size.height } ?? false)
            } action: { old, new in
                memo.isAbove = new.isAbove
                // The height of a chunk that started out drawn, or its rows
                // changing size while drawn, as when the window does.
                // Becoming drawn from a space is handled in `measured`.
                guard stage == .drawn, new.height != memo.height else { return }
                memo.height = new.height
                if new.isAbove, new.height != old.height { shift.move(new.height - old.height) }
            }
            .onGeometryChange(for: ChatTail.Reach.self) { proxy in
                // The part of the list on screen, measured from this
                // chunk's own top edge.
                guard let screen = proxy.bounds(of: .scrollView) else { return .between }
                return ChatTail.reach(top: 0, bottom: proxy.size.height, screenTop: screen.minY, screenBottom: screen.maxY)
            } action: { reach in
                switch reach {
                case .near: if stage == .space { stage = memo.height == nil ? .measuring : .drawn }
                case .far: if stage != .space { stage = .space }
                case .between: break
                }
            }
        }

        private func measured(_ height: CGFloat) {
            guard stage == .measuring, height > 0 else { return }
            let delta = height - space
            memo.height = height
            stage = .drawn
            if memo.isAbove, delta != 0 { shift.move(delta) }
        }
    }

    /// A chunk's last measured height, for the space that stands in for it.
    /// Kept out of the view's state: nothing draws from it while the chunk
    /// itself is drawn.
    private final class Memo {
        var height: CGFloat?
        var isAbove = false
    }
}

/// How a chunk of history tells the scroll view it changed height while
/// above the screen, so the scroll view can keep what you're reading still.
public struct ChatHistoryShift {
    var move: (CGFloat) -> Void = { _ in }
}

extension EnvironmentValues {
    @Entry var chatHistoryShift = ChatHistoryShift()
}

public extension Array where Element == TranscriptTurn {
    /// The id of your most recent message, for `sticksToBottom(sentKey:)`.
    var lastSentID: String? {
        last { if case .user = $0.kind { true } else { false } }?.id
    }
}
