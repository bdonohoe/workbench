import AppKit
import SwiftUI

/// Ctrl-Tab and Ctrl-Shift-Tab step through the project's tabs whatever
/// tab you're in. A terminal knew these keys already (they're Ghostty's),
/// but a chat's message box took them as typing, so the keys worked in a
/// shell tab and then stopped once you landed on Claude.
enum ControlTab {
    /// 1 for the next tab, -1 for the one before, nil for any other key.
    static func offset(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Int? {
        guard keyCode == 48 else { return nil }
        let mods = modifiers.intersection([.control, .shift, .option, .command])
        switch mods {
        case .control: return 1
        case [.control, .shift]: return -1
        default: return nil
        }
    }
}

/// Put behind the main window's content: catches Ctrl-Tab there before the
/// focused view does, and only in that window, so a sheet, popover or other
/// window keeps the keys.
struct ControlTabCycler: NSViewRepresentable {
    /// Steps the tabs by the offset, or returns false to let the key through.
    let cycle: (Int) -> Bool

    func makeNSView(context: Context) -> MonitorView { MonitorView() }
    func updateNSView(_ view: MonitorView, context: Context) { view.cycle = cycle }

    final class MonitorView: NSView {
        var cycle: (Int) -> Bool = { _ in false }
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window, window.attachedSheet == nil,
                      let offset = ControlTab.offset(keyCode: event.keyCode, modifiers: event.modifierFlags),
                      self.cycle(offset) else { return event }
                return nil
            }
        }
    }
}
