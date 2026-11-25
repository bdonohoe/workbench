import AppKit
import SwiftUI

/// The window has no toolbar. Its top band is drawn by the columns
/// themselves: the sidebar's buttons, the project's tabs, and the right
/// panel's switch, all in one row. A system toolbar would blur whatever
/// sits under it, and it would leave its own 52pt row on top of the tabs.
enum WindowChrome {
    /// The band across the top of the window.
    static let bandHeight: CGFloat = 40
    /// The row inside the band that controls sit in, at its bottom, so a
    /// tab can run straight into the card below.
    static let rowHeight: CGFloat = 30
    /// Room for the close, minimize and zoom buttons at the window's left.
    static let trafficLightsWidth: CGFloat = 78
    /// The traffic lights' middle, from the top of the window, lined up with
    /// the row's middle.
    static var rowMidY: CGFloat { bandHeight - rowHeight / 2 }
    /// Below this window width, the top band's buttons drop their labels.
    static let narrowWindowWidth: CGFloat = 560
    /// The narrowest the window goes: room for a tall, thin chat or
    /// terminal beside another app, with both sidebars out of the way.
    static let minWindowWidth: CGFloat = 360
}

/// One column's part of the top band: its controls in a row at the band's
/// bottom, and the empty space acting like a title bar.
struct WindowBand<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 4) {
            content
        }
        .frame(height: WindowChrome.rowHeight)
        .padding(.top, WindowChrome.bandHeight - WindowChrome.rowHeight)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .background(WindowTitleArea())
    }
}

extension EnvironmentValues {
    /// True when the window is too narrow for the top band's button
    /// labels, so they show just their icons and the tabs keep their room.
    @Entry var isNarrowWindow = false
}

/// Brain Dump and the sidebar button, at the top of the sidebar, or at the
/// start of the main area's band when the sidebar is hidden.
struct SidebarBandButtons: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        BarButton(symbol: "sidebar.left") {
            withAnimation(Theme.Motion.layout) {
                store.sidebarVisibility = store.sidebarVisibility == .detailOnly ? .all : .detailOnly
            }
        }
        .help(store.sidebarVisibility == .detailOnly ? "Show the sidebar" : "Collapse the sidebar to icons")
        .accessibilityLabel(store.sidebarVisibility == .detailOnly ? "Show Sidebar" : "Collapse Sidebar")
        // It can start work in any project, not just the one on screen.
        BarButton(symbol: "brain") {
            store.startSendTasks(remoteHost: store.selectedRemote?.host)
        }
        .help("Brain Dump: say what you want done and start agents in several projects (⌥⌘N)")
        .accessibilityLabel("Brain Dump")
    }
}

/// The sidebar's part of the band: room for the traffic lights, then its
/// buttons at the trailing edge.
struct SidebarBand: View {
    var body: some View {
        WindowBand {
            Spacer(minLength: WindowChrome.trafficLightsWidth)
            SidebarBandButtons()
        }
        .padding(.trailing, 8)
    }
}

/// Leading controls for the main area's band: when the sidebar is
/// collapsed to its icons, its buttons move here, after the traffic
/// lights, which sit over the icons.
struct MainBandLeading: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if store.sidebarVisibility == .detailOnly {
            Spacer().frame(width: max(0, WindowChrome.trafficLightsWidth - 8 - ProjectRail.width))
            SidebarBandButtons()
            Divider().frame(height: 16).padding(.horizontal, 4)
        }
    }
}

/// Send Feedback and the right panel's button, at the window's top right:
/// over the panel when it's open, at the end of the main area's band when
/// it isn't.
struct WindowTrailingButtons: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.isNarrowWindow) private var isNarrow

    var body: some View {
        // Feedback is also in the Help menu, so it gives way in a narrow window.
        if !isNarrow {
            BarButton(symbol: "exclamationmark.bubble") {
                openWindow(id: "feedback")
            }
            .help("Send feedback about Workbench to its developer")
            .accessibilityLabel("Send Feedback")
        }
        BarButton(symbol: "sidebar.right") {
            store.showsChanges.toggle()
        }
        .help(store.showsChanges ? "Hide the right panel (⌥⌘0)" : "Show the right panel (⌥⌘0)")
        .accessibilityLabel(store.showsChanges ? "Hide Right Panel" : "Show Right Panel")
    }
}

/// The band over a page with no tabs, like Settings or the Overview.
struct PlainMainBand: View {
    var body: some View {
        WindowBand {
            MainBandLeading()
            Spacer(minLength: 0)
            WindowTrailingButtons()
        }
        .padding(.horizontal, 8)
    }
}

/// Lines the close, minimize and zoom buttons up with the band's row, and
/// keeps them there: AppKit puts them back whenever it lays out the title
/// bar, after a resize or leaving full screen. `shift` moves them right:
/// with the sidebar collapsed to its icons they sit on the card's tab row,
/// past the icons, since the rail is too thin for them.
struct TrafficLightsPlacement: NSViewRepresentable {
    var shift: CGFloat = 0

    func makeNSView(context: Context) -> PlacementView { PlacementView() }
    func updateNSView(_ view: PlacementView, context: Context) {
        view.shift = shift
        view.place()
        // The split view lays the title bar out again after a sidebar
        // change, which puts the buttons back, so place them after that too.
        DispatchQueue.main.async { view.place() }
    }

    final class PlacementView: NSView {
        private var observers: [NSObjectProtocol] = []
        private var placing = false
        var shift: CGFloat = 0
        /// Where AppKit puts each button across, before any shift.
        private var homeX: [NSWindow.ButtonType: CGFloat] = [:]

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            // Leaving the window (or going away) drops the observers above.
            guard let window else { return }
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
            ]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.place() }
                })
            }
            if let close = window.standardWindowButton(.closeButton) {
                // The buttons, and the container they're in: AppKit resizes
                // the container back to a plain title bar's height now and then.
                for view in [close, close.superview?.superview].compactMap({ $0 }) {
                    view.postsFrameChangedNotifications = true
                    observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.placeSoon() }
                    })
                }
            }
            DispatchQueue.main.async { self.place() }
        }

        private var placeScheduled = false

        /// Places the buttons once AppKit has finished the layout pass that
        /// moved them, so the move sticks.
        func placeSoon() {
            guard !placeScheduled else { return }
            placeScheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.placeScheduled = false
                self?.place()
            }
        }

        func place() {
            guard !placing, let window, !window.styleMask.contains(.fullScreen),
                  let close = window.standardWindowButton(.closeButton),
                  let container = close.superview?.superview else { return }
            placing = true
            defer { placing = false }
            // The buttons live in the title bar's container, which is only
            // as tall as a plain title bar. Make it as tall as the band so
            // the buttons can sit lower and still take clicks.
            let band = WindowChrome.bandHeight
            let frame = NSRect(x: 0, y: window.frame.height - band, width: window.frame.width, height: band)
            if container.frame != frame { container.frame = frame }
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                guard let button = window.standardWindowButton(kind) else { continue }
                // In the button's superview, which now fills the container.
                let y = band - WindowChrome.rowMidY - button.frame.height / 2
                // AppKit's own x is the one that isn't a shift we made.
                let home = homeX[kind] ?? button.frame.origin.x
                homeX[kind] = home
                let x = home + shift
                if abs(button.frame.origin.y - y) > 0.5 || abs(button.frame.origin.x - x) > 0.5 {
                    button.setFrameOrigin(NSPoint(x: x, y: y))
                }
            }
        }
    }
}
