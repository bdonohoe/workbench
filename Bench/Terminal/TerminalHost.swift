import AppKit
import SwiftUI

/// Shows one session's terminal view. The view itself is owned by the
/// session, so switching tabs or projects just moves it in and out of this
/// container instead of recreating the shell.
struct TerminalHost: NSViewRepresentable {
    let session: TerminalSession
    /// The terminal's background, shown in the small inset around it.
    var background: NSColor?
    var cornerRadius: CGFloat = 0
    /// False while it's hidden under a chat, so it doesn't take the keys.
    var takesFocus = true

    func makeNSView(context: Context) -> ContainerView {
        let container = ContainerView()
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        container.layer?.cornerCurve = .continuous
        updateNSView(container, context: context)
        return container
    }

    func updateNSView(_ container: ContainerView, context: Context) {
        container.layer?.cornerRadius = cornerRadius
        container.layer?.backgroundColor = background?.cgColor
        // Keeps text clear of the rounded corners.
        container.inset = cornerRadius > 0 ? 4 : 0
        container.takesFocus = takesFocus
        container.show(session)
    }

    static func dismantleNSView(_ container: ContainerView, coordinator: ()) {
        container.show(nil)
    }

    final class ContainerView: NSView {
        private var current: TerminalSession?
        /// In a split, flips as you switch sides: the keyboard follows.
        var takesFocus = true {
            didSet {
                guard takesFocus != oldValue, let view = current?.view, view.superview === self else { return }
                if takesFocus {
                    focus(view)
                } else if view.window?.firstResponder === view {
                    view.window?.makeFirstResponder(nil)
                }
            }
        }
        var inset: CGFloat = 0 {
            didSet { if inset != oldValue { layoutTerminal() } }
        }

        /// A new window gives the keyboard to its first terminal on its
        /// own, which in a split may be the wrong side. Takes it back.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if takesFocus, window != nil, let view = current?.view, view.superview === self { focus(view) }
        }

        override func layout() {
            super.layout()
            layoutTerminal()
        }

        private func layoutTerminal() {
            // While SwiftUI measures, the container can be given an
            // infinite or absurd size for a moment. A frame made from that
            // turns into layout constraints with constants past Auto
            // Layout's limit, which with the panel open at a narrow width
            // crashed the window. Keep the last real frame instead.
            let target = bounds.insetBy(dx: inset, dy: inset)
            guard target.width.isFinite, target.height.isFinite,
                  target.width >= 0, target.height >= 0,
                  target.width < 100_000, target.height < 100_000 else { return }
            current?.view.frame = target
        }

        func show(_ session: TerminalSession?) {
            guard session !== current else { return }
            // Going from one pane to a split can show a session in a new
            // container before the old one lets go. Only let go of a view
            // that's still here.
            if let current, current.view.superview === self {
                current.isVisible = false
                current.view.removeFromSuperview()
            }
            current = session
            guard let session else { return }

            let view = session.view
            view.removeFromSuperview()
            // layout() places the view itself, so it needs no autoresizing
            // mask; translating one into constraints is what overflowed.
            view.autoresizingMask = []
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            layoutTerminal()
            session.isVisible = true
            if takesFocus { focus(view) }
        }

        private func focus(_ view: NSView) {
            DispatchQueue.main.async { [weak view] in
                guard let view, let window = view.window else { return }
                window.makeFirstResponder(view)
            }
        }
    }
}
