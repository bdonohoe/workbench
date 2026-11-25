import AppKit
import Foundation

/// The key you hold to dictate. All modifier keys on the right-hand side,
/// which typing rarely uses, plus Fn.
enum DictationKey: String, CaseIterable, Identifiable {
    case rightOption, rightCommand, rightControl, fn

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rightOption: "Right Option (⌥)"
        case .rightCommand: "Right Command (⌘)"
        case .rightControl: "Right Control (⌃)"
        case .fn: "Fn / Globe"
        }
    }

    /// Short key symbol for hints beside the message box.
    var glyph: String {
        switch self {
        case .rightOption: "right ⌥"
        case .rightCommand: "right ⌘"
        case .rightControl: "right ⌃"
        case .fn: "fn"
        }
    }

    /// Keycode of the physical key, as flagsChanged reports it.
    var keyCode: UInt16 {
        switch self {
        case .rightOption: 61
        case .rightCommand: 54
        case .rightControl: 62
        case .fn: 63
        }
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .rightOption: .option
        case .rightCommand: .command
        case .rightControl: .control
        case .fn: .function
        }
    }
}

/// The decisions behind the dictation key, apart from the events that feed
/// it, so they can be tested. From Dict's logic of the same name:
/// recording starts the moment the key goes down so no speech is lost, a
/// quick tap is thrown away, and Space while holding goes hands-free.
struct DictationKeyLogic {
    enum Action: Equatable { case start, stop, cancel, enterHandsFree }

    /// Releases sooner than this count as accidental taps.
    static let holdThreshold: Duration = .milliseconds(150)

    private(set) var isKeyHeld = false
    private(set) var isRecording = false
    private(set) var handsFree = false
    private var keyDownTime: ContinuousClock.Instant?

    mutating func keyDown(now: ContinuousClock.Instant = ContinuousClock().now) -> Action? {
        guard !isKeyHeld else { return nil }
        isKeyHeld = true
        // Hands-free: the next press of the key finishes.
        if handsFree {
            handsFree = false
            isRecording = false
            return .stop
        }
        guard !isRecording else { return nil }
        isRecording = true
        keyDownTime = now
        return .start
    }

    mutating func keyUp(now: ContinuousClock.Instant = ContinuousClock().now) -> Action? {
        isKeyHeld = false
        guard !handsFree, isRecording else { return nil }
        isRecording = false
        let heldLongEnough = keyDownTime.map { now - $0 >= Self.holdThreshold } ?? true
        keyDownTime = nil
        return heldLongEnough ? .stop : .cancel
    }

    /// Space while holding the key: keep listening after it's let go.
    mutating func spaceDown() -> Action? {
        guard isRecording, isKeyHeld, !handsFree else { return nil }
        handsFree = true
        return .enterHandsFree
    }

    /// Whether a Space should be swallowed rather than typed: it's about
    /// to switch to hands-free.
    var swallowsSpace: Bool { isRecording && isKeyHeld && !handsFree }

    /// Escape abandons a recording, held or hands-free. Nil when nothing
    /// is recording, so the key does whatever it normally does.
    mutating func escapeDown() -> Action? {
        guard isRecording else { return nil }
        reset()
        return .cancel
    }

    /// Any other key while the dictation key is held means the key was
    /// being used as an ordinary modifier (Option-Delete, say), so the
    /// recording that began with it is thrown away. Hands-free recordings
    /// carry on: the key is up by then.
    mutating func otherKeyDown() -> Action? {
        guard isRecording, isKeyHeld, !handsFree else { return nil }
        isRecording = false
        keyDownTime = nil
        return .cancel
    }

    /// A recording started some other way (the microphone button), which
    /// the key can then finish like a hands-free one.
    mutating func beganHandsFree() {
        isRecording = true
        handsFree = true
        keyDownTime = nil
    }

    /// The recording ended, or never began: forget it. The key itself may
    /// still be down.
    mutating func reset() {
        isRecording = false
        handsFree = false
        keyDownTime = nil
    }
}
