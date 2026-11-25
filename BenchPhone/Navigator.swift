import Foundation
import Observation
import SwiftUI

/// Where the app is, so a notification tap or a "started" reply from the
/// Mac can take you straight to a session.
///
/// A phone keeps one stack: projects, then a project, then deeper screens.
/// A wide iPad window shows projects in a sidebar like the Mac, so it
/// keeps the chosen project and the screens stacked on top of it apart.
/// Both are kept up to date, so turning or resizing the iPad between the
/// two layouts stays on the same project.
@Observable
final class Navigator {
    /// The phone's stack.
    var path = NavigationPath()
    /// The project picked in the iPad's sidebar.
    var selected: UUID?
    /// A session to show straight away for the selected project, when a
    /// notification or the Mac pointed at one.
    var selectedSession: UUID?
    /// The iPad's stack above the selected project.
    var detailPath = NavigationPath()
    /// A web link from a notification (a pull request), opened once the
    /// app is up.
    var pendingURL: URL?
    /// True while the Send Tasks sheet is up.
    var showsSendTasks = false
    /// What the iPad's inspector last opened in the middle pane, and how
    /// deep the stacks were then, so the next file replaces it instead of
    /// piling up.
    private var inspectorItem: InspectorItem?
    private var inspectorDepth: (detail: Int, phone: Int)?

    func open(projectID: UUID, sessionID: UUID?) {
        var path = NavigationPath()
        // Straight to the session, as a row in the list would: the project
        // screen underneath would open the same conversation a second time.
        if let sessionID {
            path.append(SessionRoute(projectID: projectID, sessionID: sessionID))
        } else {
            path.append(projectID)
        }
        self.path = path
        selected = projectID
        selectedSession = sessionID
        detailPath = NavigationPath()
        inspectorDepth = nil
    }

    /// Picks a project in the iPad's sidebar.
    func select(_ projectID: UUID) {
        selected = projectID
        selectedSession = nil
        detailPath = NavigationPath()
        var path = NavigationPath()
        path.append(projectID)
        self.path = path
        inspectorDepth = nil
    }

    /// Goes one screen further from the current project, in both layouts.
    func push<Route: Hashable>(_ route: Route) {
        path.append(route)
        detailPath.append(route)
        // Something else on top now: the inspector's item isn't showing.
        inspectorDepth = nil
    }

    /// Shows a diff, file or commit from the inspector in the middle pane,
    /// in place of the one it showed last if that's still on top.
    func show(_ item: InspectorItem) {
        if let depth = inspectorDepth, depth.detail == detailPath.count, depth.detail > 0 {
            detailPath.removeLast()
            if depth.phone == path.count, depth.phone > 0 { path.removeLast() }
        }
        switch item {
        case .diff(let route): push(route)
        case .file(let route): push(route)
        case .commit(let route): push(route)
        }
        inspectorItem = item
        inspectorDepth = (detailPath.count, path.count)
    }

    /// The inspector's item, while it's still the screen on top.
    var shownInspectorItem: InspectorItem? {
        guard let depth = inspectorDepth, depth.detail == detailPath.count else { return nil }
        return inspectorItem
    }

    func reset() {
        path = NavigationPath()
        selected = nil
        selectedSession = nil
        detailPath = NavigationPath()
        inspectorDepth = nil
    }
}

/// Something the iPad's inspector opens in the middle pane.
enum InspectorItem: Hashable {
    case diff(DiffRoute)
    case file(FileRoute)
    case commit(CommitRoute)
}

/// The iPad's inspector, for the screens that show its button.
struct InspectorToggle {
    var isShown: Bool
    var toggle: () -> Void
}

extension EnvironmentValues {
    /// Shows or hides the iPad's project sidebar. Set only on the screen at
    /// the bottom of the iPad's detail stack, where there's nothing to go
    /// back to, so a screen with its own header shows this instead of Back.
    @Entry var toggleSidebar: (() -> Void)?

    /// True where the system runs its bar down the side of the screen: an
    /// iPhone Duo that's closed, or open and turned sideways. Never true on
    /// other iPhones or an iPad.
    var hasVerticalBar: Bool {
        if #available(iOS 27.1, *) { toolbarVerticalEdge != nil } else { false }
    }
    /// Shows or hides the iPad's inspector. Set wherever the inspector can
    /// show, so headers draw its button and menus leave out what it holds.
    @Entry var inspector: InspectorToggle?
    /// Set inside the inspector: diffs, files and commits open in the
    /// middle pane through this rather than inside the narrow pane.
    @Entry var showInMain: ((InspectorItem) -> Void)?
}
