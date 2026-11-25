import AppKit
import BenchKit
import Foundation

/// Where a click on one of Claude's published pages (a claude.ai artifact
/// link) goes: a Workbench tab, or your web browser. Asked the first time
/// you click one, and changeable in Settings after that.
enum ArtifactLinkTarget: String, CaseIterable {
    case workbench
    case browser
}

/// Every link click from a chat, a terminal, the Artifacts panel or a
/// notification comes through here, so artifact links all open the same way.
@MainActor
enum ArtifactLinks {
    /// The `ArtifactLinkTarget` you picked. Unset until the first click.
    static let targetKey = "artifactLinkTarget"

    /// Set at launch, so clicks that come from AppKit can open tabs.
    static weak var store: AppStore?

    static var target: ArtifactLinkTarget? {
        get { UserDefaults.standard.string(forKey: targetKey).flatMap(ArtifactLinkTarget.init) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: targetKey) }
    }

    static func isArtifact(_ url: URL) -> Bool { ArtifactPublish.isArtifactURL(url.absoluteString) }

    /// Opens an artifact link the way you chose, asking the first time.
    /// Returns false for any other link, which the caller opens as usual.
    @discardableResult
    static func handle(_ url: URL) -> Bool {
        guard isArtifact(url) else { return false }
        let chosen = target ?? ask()
        switch chosen {
        case .workbench: openInWorkbench(url)
        case .browser: NSWorkspace.shared.open(url)
        }
        Analytics.capture(.artifactOpened, ["in": chosen.rawValue])
        return true
    }

    /// Opens any link: artifacts by `handle`, everything else in its app.
    static func open(_ url: URL) {
        if !handle(url) { NSWorkspace.shared.open(url) }
    }

    /// In a tab of the current project, with the page's name when it's
    /// known. Without a project on screen it goes to the browser instead.
    static func openInWorkbench(_ url: URL) {
        guard let store, let project = store.selectedProject, store.selectedRemote == nil else {
            NSWorkspace.shared.open(url)
            return
        }
        let title = ArtifactLibrary.shared.links(for: project).first { $0.url == url.absoluteString }?.title
        store.openArtifact(url, title: title, in: project.id)
    }

    /// The first click: which way should artifacts open from now on?
    private static func ask() -> ArtifactLinkTarget {
        let alert = NSAlert()
        alert.messageText = "Where should artifacts open?"
        alert.informativeText = "Pages Claude publishes can open in a Workbench tab, where you can split them beside your chat, or in your web browser. You can change this later in Settings, under Agents."
        alert.addButton(withTitle: "In Workbench")
        alert.addButton(withTitle: "In Browser")
        let choice: ArtifactLinkTarget = alert.runModal() == .alertFirstButtonReturn ? .workbench : .browser
        target = choice
        Analytics.capture(.artifactTargetChosen, ["target": choice.rawValue])
        return choice
    }
}
