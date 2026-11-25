import Foundation

/// Watches a session's output for the settings a program gives its
/// terminal, so a new window that attaches later can be given them too.
///
/// A relaunched Workbench opens a fresh terminal, which knows nothing of
/// what Claude switched on when it started: bracketed paste, the enhanced
/// keyboard protocol (Shift+Return), focus and mouse reporting, the window
/// title, and the progress signal Workbench reads to tell Claude is
/// working. Programs set these once and don't repeat them when asked to
/// redraw, so the keeper replays them first.
struct TerminalMemory {
    /// DEC private modes worth carrying over, and whether each is on.
    private static let trackedModes: Set<Int> = [
        1,     // cursor keys send application sequences
        25,    // cursor visible
        47, 1047, 1049, // alternate screen
        1000, 1002, 1003, 1005, 1006, 1015, // mouse reporting
        1004,  // focus in and out
        2004,  // bracketed paste
    ]
    private var modes: [Int: Bool] = [:]
    /// The kitty keyboard protocol's stack of flags, oldest first.
    private var keyboardFlags: [Int] = []
    /// xterm's modifyOtherKeys, as last set.
    private var modifyOtherKeys: String?
    private var title: String?
    private var progress: String?

    private enum State { case normal, escape, csi, osc, oscEscape }
    private var state = State.normal
    private var sequence: [UInt8] = []

    mutating func feed<Bytes: Collection>(_ bytes: Bytes) where Bytes.Element == UInt8 {
        for byte in bytes {
            switch state {
            case .normal:
                if byte == 0x1b { state = .escape }
            case .escape:
                switch byte {
                case UInt8(ascii: "["): state = .csi; sequence.removeAll(keepingCapacity: true)
                case UInt8(ascii: "]"): state = .osc; sequence.removeAll(keepingCapacity: true)
                case UInt8(ascii: "c"): self = TerminalMemory(); state = .normal
                case 0x1b: state = .escape
                default: state = .normal
                }
            case .csi:
                if (0x40...0x7e).contains(byte) {
                    finishCSI(final: byte)
                    state = .normal
                } else if byte == 0x1b {
                    state = .escape
                } else if byte < 0x20 || sequence.count > 64 {
                    state = .normal
                } else {
                    sequence.append(byte)
                }
            case .osc:
                if byte == 0x07 {
                    finishOSC()
                    state = .normal
                } else if byte == 0x1b {
                    state = .oscEscape
                } else if sequence.count > 4096 {
                    state = .normal
                } else {
                    sequence.append(byte)
                }
            case .oscEscape:
                if byte == UInt8(ascii: "\\") { finishOSC() }
                state = byte == 0x1b ? .escape : .normal
            }
        }
    }

    private mutating func finishCSI(final: UInt8) {
        let text = String(decoding: sequence, as: UTF8.self)
        let prefix = text.first.flatMap { "?<>=".contains($0) ? $0 : nil }
        let body = prefix == nil ? Substring(text) : text.dropFirst()
        let numbers = body.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) }
        switch (prefix, final) {
        case ("?", UInt8(ascii: "h")), ("?", UInt8(ascii: "l")):
            for case let mode? in numbers where Self.trackedModes.contains(mode) {
                modes[mode] = final == UInt8(ascii: "h")
            }
        case (">", UInt8(ascii: "u")):
            keyboardFlags.append((numbers.first ?? 0) ?? 0)
            if keyboardFlags.count > 16 { keyboardFlags.removeFirst() }
        case ("<", UInt8(ascii: "u")):
            let count = max((numbers.first ?? 1) ?? 1, 1)
            keyboardFlags.removeLast(min(count, keyboardFlags.count))
        case ("=", UInt8(ascii: "u")):
            let flags = (numbers.first ?? 0) ?? 0
            let how = numbers.count > 1 ? (numbers[1] ?? 1) : 1
            if keyboardFlags.isEmpty { keyboardFlags.append(0) }
            switch how {
            case 2: keyboardFlags[keyboardFlags.count - 1] |= flags
            case 3: keyboardFlags[keyboardFlags.count - 1] &= ~flags
            default: keyboardFlags[keyboardFlags.count - 1] = flags
            }
        case (">", UInt8(ascii: "m")) where numbers.first == 4:
            modifyOtherKeys = text
        default:
            break
        }
    }

    private mutating func finishOSC() {
        let text = String(decoding: sequence, as: UTF8.self)
        if text.hasPrefix("0;") || text.hasPrefix("2;") {
            title = text
        } else if text.hasPrefix("9;4") {
            progress = text
        }
    }

    /// What to send a fresh terminal so it matches this one.
    var replay: Data {
        var out = ""
        // The alternate screen first, so what follows lands on it.
        for mode in [47, 1047, 1049] where modes[mode] == true { out += "\u{1b}[?\(mode)h" }
        for (mode, on) in modes.sorted(by: { $0.key < $1.key }) where ![47, 1047, 1049].contains(mode) {
            out += "\u{1b}[?\(mode)\(on ? "h" : "l")"
        }
        for flags in keyboardFlags { out += "\u{1b}[>\(flags)u" }
        if let modifyOtherKeys { out += "\u{1b}[\(modifyOtherKeys)m" }
        if let title { out += "\u{1b}]\(title)\u{07}" }
        if let progress { out += "\u{1b}]\(progress)\u{07}" }
        return Data(out.utf8)
    }
}
