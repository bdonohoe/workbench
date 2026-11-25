import BenchKit
import SwiftUI

/// The microphone in a message box's row of buttons, shown while dictation
/// is turned on in Settings. Click to start talking hands-free, click
/// again to finish. Holding the dictation key does the same without it.
struct DictationMicButton: View {
    @Environment(\.companionPalette) private var palette
    /// The message box this button belongs to.
    let target: UUID
    let isEnabled: Bool
    let action: () -> Void
    private var dictation: Dictation { .shared }

    private var isMine: Bool { dictation.activeTarget == target && dictation.isBusy }

    var body: some View {
        Button(action: action) {
            ZStack {
                if isMine, dictation.phase == .finishing {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                } else {
                    // Swells with your voice, so it's plain it can hear you.
                    Circle()
                        .fill(palette.accent.opacity(isMine ? 0.2 : 0))
                        .scaleEffect(isMine ? 0.85 + CGFloat(dictation.level) * 0.3 : 0.6)
                        .animation(.easeOut(duration: 0.1), value: dictation.level)
                    Image(systemName: isMine ? "mic.fill" : "mic")
                        .font(.ui(size: 13))
                        .foregroundStyle(isMine ? palette.accent : palette.inkMuted)
                }
            }
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .animation(Theme.Motion.state, value: isMine)
        }
        .buttonStyle(.pressable)
        .disabled(!isEnabled || (dictation.isBusy && !isMine) || (isMine && dictation.phase == .finishing))
        .help(isMine ? "Finish dictating" : "Dictate: hold \(dictation.key.glyph) and talk, or click here to start and again to finish")
        .accessibilityLabel(isMine ? "Finish dictating" : "Dictate")
    }
}

/// What dictation is doing, beside the buttons under the message: bars
/// that move with your voice while it listens, and a line saying how to
/// finish.
struct DictationStatusLabel: View {
    @Environment(\.companionPalette) private var palette
    private var dictation: Dictation { .shared }

    /// The line to show, longest first: the message box's row is shared
    /// with the mode, model and context controls, so on a narrow window
    /// the full sentence doesn't fit and a shorter one stands in.
    private var lines: [String] {
        if let note = dictation.note, !dictation.isBusy { return [note] }
        switch dictation.phase {
        case .idle: return [""]
        case .finishing: return ["Writing it out…"]
        case .starting, .listening:
            return dictation.isHandsFree
                ? ["Listening. Press \(dictation.key.glyph) or click the microphone when you're done.",
                   "Press \(dictation.key.glyph) when you're done",
                   "\(dictation.key.glyph) to finish",
                   "Listening"]
                : ["Listening. Let go when you're done, or tap Space to keep going hands-free.",
                   "Let go to finish, Space to keep going",
                   "Space to keep going",
                   "Listening"]
        }
    }

    private var isListening: Bool {
        dictation.phase == .starting || dictation.phase == .listening
    }

    var body: some View {
        HStack(spacing: 6) {
            if isListening {
                LevelBars(level: dictation.level, color: palette.accent)
                    .transition(.opacity)
            }
            ViewThatFits(in: .horizontal) {
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .font(.ui(size: 11))
            .foregroundStyle(dictation.isBusy ? palette.accent : palette.inkMuted)
        }
        .padding(.leading, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(lines[0])
    }
}

/// Four small bars that rise with the microphone's level.
private struct LevelBars: View {
    let level: Float
    let color: Color
    /// The middle bars reach higher, like a voice's shape.
    private static let reach: [CGFloat] = [0.55, 1, 0.8, 0.45]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<Self.reach.count, id: \.self) { index in
                Capsule()
                    .fill(color)
                    .frame(width: 2, height: 3 + CGFloat(level) * 10 * Self.reach[index])
            }
        }
        .frame(height: 13)
        .animation(.easeOut(duration: 0.1), value: level)
        .accessibilityHidden(true)
    }
}

#if DEBUG
/// The microphone button and its status line in each state, and the
/// Settings page on and off, to PNGs in light and dark.
/// BENCH_RENDER_DICTATION=<folder>. Nothing is recorded: the states are
/// set by hand.
enum DictationPreview {
    static func render(to folder: URL) {
        _ = NSApplication.shared
        let palette = TerminalTheme.shared.chatPalette
        let box = UUID()
        let states: [(String, Dictation.Phase, Bool, Float, String?)] = [
            ("Off duty", .idle, false, 0, nil),
            ("Holding the key", .listening, false, 0.7, nil),
            ("Hands-free", .listening, true, 0.35, nil),
            ("Writing it out", .finishing, false, 0, nil),
            ("Nothing heard", .idle, false, 0, "Didn't catch anything."),
        ]
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for (index, state) in states.enumerated() { for width in [560.0, 330, 250, 190] {
                Dictation.shared.stage(phase: state.1, handsFree: state.2, level: state.3, note: state.4, target: box)
                let row = VStack(alignment: .leading, spacing: 8) {
                    Text(state.0).font(.ui(size: 11, weight: .semibold)).foregroundStyle(palette.inkMuted)
                    HStack(spacing: 8) {
                        Image(systemName: "paperclip").font(.ui(size: 13)).frame(width: 24, height: 24).foregroundStyle(palette.inkMuted)
                        Image(systemName: "slash.circle").font(.ui(size: 13)).frame(width: 24, height: 24).foregroundStyle(palette.inkMuted)
                        DictationMicButton(target: box, isEnabled: true) {}
                        if Dictation.shared.activeTarget == box { DictationStatusLabel() }
                        Spacer(minLength: 0)
                    }
                }
                .padding(16)
                .frame(width: width, alignment: .leading)
                .background(palette.surface)
                .environment(\.companionPalette, palette)
                write(row, appearance: appearance, to: folder.appendingPathComponent("dictation-\(index)-\(Int(width))-\(name).png"))
            } }
            Dictation.shared.stage(phase: .idle, handsFree: false, level: 0, note: nil, target: box)
            for (label, enabled, model) in [("off", false, Dictation.ModelState.missing),
                                            ("downloading", true, .downloading(0.43)),
                                            ("ready", true, .ready)] {
                Dictation.shared.stage(enabled: enabled, model: model)
                let page = VStack(alignment: .leading, spacing: 22) { DictationSettings() }
                    .padding(28)
                    .frame(width: 760, alignment: .leading)
                    .background(TerminalTheme.shared.canvas)
                write(page, appearance: appearance, to: folder.appendingPathComponent("dictation-settings-\(label)-\(name).png"))
            }
        }
    }

    private static func write(_ view: some View, appearance: NSAppearance.Name, to url: URL) {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.setFrameSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
