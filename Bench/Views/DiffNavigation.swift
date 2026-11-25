import BenchKit
import SwiftUI

// MARK: Change marks in the file view

/// How a line of a file differs from the version it's compared with, shown
/// as a bar in the file view's gutter.
enum ChangeMark: Equatable {
    case added
    case changed
    /// Lines were removed just above this one.
    case removedAbove
}

extension ChangeMark {
    /// Marks by line (from 0), from a diff with no context lines. Each
    /// hunk header says it all: "@@ -10,2 +9,0 @@" removed two lines after
    /// line 9, "+9,3" with nothing on the old side added three, and both
    /// together changed them.
    static func marks(fromZeroContextDiff diff: String) -> [Int: ChangeMark] {
        var marks: [Int: ChangeMark] = [:]
        for line in diff.split(separator: "\n") where line.hasPrefix("@@ ") {
            let parts = line.split(separator: " ")
            guard parts.count >= 3, let old = range(parts[1]), let new = range(parts[2]) else { continue }
            if new.count == 0 {
                // Removed after line `start`, so the mark goes on the next line.
                let below = new.start
                if marks[below] == nil { marks[below] = .removedAbove }
            } else {
                for line in (new.start - 1)..<(new.start - 1 + new.count) {
                    marks[line] = old.count == 0 ? .added : .changed
                }
            }
        }
        return marks
    }

    /// "-10,2" or "+9" as a start line and a count (1 when left out).
    private static func range(_ part: Substring) -> (start: Int, count: Int)? {
        let numbers = part.dropFirst().split(separator: ",")
        guard let start = numbers.first.flatMap({ Int($0) }) else { return nil }
        let count = numbers.count > 1 ? Int(numbers[1]) ?? 1 : 1
        return (start, count)
    }

    var color: NSColor {
        switch self {
        case .added: NSColor(Theme.Status.done)
        case .changed: .systemOrange
        case .removedAbove: NSColor(Theme.Status.failed)
        }
    }
}

// MARK: Header controls

/// Which view a changed file's tab shows: what changed, or the whole file.
/// Switching keeps the same tab.
struct ChangesFileSwitch: View {
    enum Mode: Hashable { case changes, file }
    let mode: Mode
    let select: (Mode) -> Void

    var body: some View {
        Picker("View", selection: Binding(get: { mode }, set: { if $0 != mode { select($0) } })) {
            Text("Changes").tag(Mode.changes)
            Text("File").tag(Mode.file)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .help("Show what changed, or the whole file")
    }
}

/// A request to move to the next or previous change. A new id each time,
/// so pressing the same button twice moves twice.
struct ChangeJump: Equatable {
    var id = 0
    var forward = true
}

/// The previous and next change buttons, with ⌃⌥↑ and ⌃⌥↓ when the tab
/// has the keys.
struct ChangeStepButtons: View {
    var hasKeys: Bool
    let step: (Bool) -> Void

    var body: some View {
        HStack(spacing: 0) {
            button(forward: false)
            button(forward: true)
        }
    }

    @ViewBuilder private func button(forward: Bool) -> some View {
        let label = Button {
            step(forward)
        } label: {
            Image(systemName: forward ? "chevron.down" : "chevron.up")
                .frame(width: 20, height: 18)
        }
        .buttonStyle(.borderless)
        .help(forward ? "Next change (⌃⌥↓)" : "Previous change (⌃⌥↑)")
        if hasKeys {
            label.keyboardShortcut(forward ? .downArrow : .upArrow, modifiers: [.control, .option])
        } else {
            label
        }
    }
}

extension GitSnapshot {
    /// The changed files in the order the changes list shows them, each
    /// path once, for stepping from file to file.
    func filesInOrder(section: ChangeSection?) -> [FileChange] {
        let all: [FileChange]
        switch section {
        case .staged: all = staged
        case .unstaged: all = unstaged
        case .againstBase: all = againstBase
        case nil: all = unstaged + staged + againstBase
        }
        var seen: Set<String> = []
        return all.filter { seen.insert($0.path).inserted }
    }
}
