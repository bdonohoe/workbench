import SwiftUI

/// What you can do with a queued message: move it back into the message
/// box to change it, or drop it. The other queued messages stay queued.
///
/// Equal when made for the same queue, so putting a fresh copy in the
/// environment each draw doesn't make every row that reads it draw again.
public struct QueueActions: Equatable {
    public var edit: (TranscriptTurn) -> Void
    public var remove: (TranscriptTurn) -> Void
    /// Sends everything queued right away, where the Mac can.
    public var sendNow: (() -> Void)?
    /// What these actions are for: the queued messages and what's offered.
    public var key: String

    public init(edit: @escaping (TranscriptTurn) -> Void, remove: @escaping (TranscriptTurn) -> Void,
                sendNow: (() -> Void)? = nil, key: String = "") {
        self.edit = edit
        self.remove = remove
        self.sendNow = sendNow
        self.key = key
    }

    public static func == (a: QueueActions, b: QueueActions) -> Bool { a.key == b.key }

    /// Builds the actions for a conversation's queue. `takeBack` gets every
    /// queued message's text and the ones to queue again; `toDraft` gets
    /// the text that's being edited.
    public static func forQueue(_ queued: [TranscriptTurn],
                                takeBack: @escaping (_ queued: [String], _ keep: [String]) -> Void,
                                sendNow: (() -> Void)? = nil,
                                toDraft: @escaping (String) -> Void) -> QueueActions {
        let texts = queued.map(\.queuedText)
        func others(_ turn: TranscriptTurn) -> [String] { queued.filter { $0.id != turn.id }.map(\.queuedText) }
        return QueueActions(
            edit: { turn in
                toDraft(turn.queuedText)
                takeBack(texts, others(turn))
            },
            remove: { turn in takeBack(texts, others(turn)) },
            sendNow: sendNow,
            key: queued.map(\.id).joined(separator: "\n") + (sendNow == nil ? "" : "\n+sendNow"))
    }
}

public extension TranscriptTurn {
    /// The words of a queued message.
    var queuedText: String {
        if case .user(let message) = kind { message.text } else { "" }
    }
}

extension EnvironmentValues {
    /// Set where queued messages can be edited or removed.
    @Entry public var queueActions: QueueActions?
}

/// "Queued. The agent reads it after this step.", with Edit and Remove when
/// the queue can be changed.
public struct QueuedCaption: View {
    @Environment(\.companionPalette) private var palette
    @Environment(\.queueActions) private var actions
    let turn: TranscriptTurn
    let font: Font

    public init(turn: TranscriptTurn, font: Font) {
        self.turn = turn
        self.font = font
    }

    public var body: some View {
        // The buttons go under the words when they don't fit beside them.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                label
                buttons
            }
            VStack(alignment: .trailing, spacing: 6) {
                label
                HStack(spacing: 14) { buttons }
            }
        }
        .font(font)
        .buttonStyle(.borderless)
        .tint(palette.accent)
    }

    private var label: some View {
        Label("Queued. The agent reads it after this step.", systemImage: "clock")
            .foregroundStyle(palette.inkMuted)
    }

    @ViewBuilder private var buttons: some View {
        if let actions {
            if let sendNow = actions.sendNow {
                Button("Send Now", action: sendNow)
                    .fontWeight(.semibold)
                    .help("The agent stops the step it's on and reads your queued messages now")
            }
            Button("Edit") { actions.edit(turn) }
            Button("Remove") { actions.remove(turn) }
        }
    }
}

public extension View {
    /// Edit and Remove in a queued message's context menu.
    func queuedMenu(_ turn: TranscriptTurn) -> some View {
        modifier(QueuedMenu(turn: turn))
    }
}

private struct QueuedMenu: ViewModifier {
    @Environment(\.queueActions) private var actions
    let turn: TranscriptTurn

    func body(content: Content) -> some View {
        if let actions, turn.isQueued {
            content.contextMenu {
                if let sendNow = actions.sendNow {
                    Button("Send Now", systemImage: "arrow.up.circle", action: sendNow)
                }
                Button("Edit", systemImage: "pencil") { actions.edit(turn) }
                Button("Remove", systemImage: "trash", role: .destructive) { actions.remove(turn) }
            }
        } else {
            content
        }
    }
}
