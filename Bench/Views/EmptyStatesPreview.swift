#if DEBUG
import AppKit
import BenchKit
import SwiftUI

/// Draws the illustrated empty states to PNGs, light and dark, so they can
/// be checked without a screen. BENCH_RENDER_EMPTY_STATES=<folder>.
@MainActor
enum EmptyStatesPreview {
    static func render(to folder: URL) {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let states: [(String, CGSize, AnyView)] = [
            ("chat", CGSize(width: 720, height: 480), AnyView(
                EmptyStateScaffold(title: "Ready when you are",
                                   message: "Tell \(Agents.standard.name) what to work on. Type `/` for commands, or `@` to point it at a file.") {
                    ConversationEmptyIllustration(appeared: $0)
                })),
            ("no-project", CGSize(width: 720, height: 480), AnyView(
                EmptyStateScaffold(title: "No Project Selected",
                                   message: "Pick one in the sidebar. To bring in a new one, add its folder or drag it into the sidebar.",
                                   actionTitle: "Add Project…", action: {}) {
                    ProjectsEmptyIllustration(appeared: $0)
                })),
            ("overview", CGSize(width: 720, height: 480), AnyView(
                EmptyStateScaffold(title: "No Agent Sessions",
                                   message: "Open an agent tab in any project and it shows up here, or use Brain Dump to start work in several projects at once.",
                                   actionTitle: "Brain Dump…", action: {}) {
                    SessionsEmptyIllustration(appeared: $0)
                })),
            ("artifacts", CGSize(width: 320, height: 480), AnyView(
                EmptyStateScaffold(title: "No Artifacts Yet",
                                   message: "Pages Claude publishes for this project, like dashboards and mockups, show up here.",
                                   size: .compact) {
                    ArtifactsEmptyIllustration(appeared: $0)
                })),
            ("changes", CGSize(width: 320, height: 480), AnyView(
                EmptyStateScaffold(title: "No Changes",
                                   message: "Edits in this project show up here as they happen.",
                                   size: .compact) {
                    ChangesEmptyIllustration(appeared: $0, branch: "main")
                })),
            ("review", CGSize(width: 720, height: 480), AnyView(
                EmptyStateScaffold(title: "No Changes", message: "This branch has no commits of its own yet.") {
                    DiffEmptyIllustration(appeared: $0)
                })),
        ]
        for (look, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for (name, size, view) in states {
                let palette = TerminalTheme.shared.chatPalette
                let host = NSHostingView(rootView: view
                    .environment(\.companionPalette, palette)
                    .frame(width: size.width, height: size.height)
                    .background(palette.canvas))
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearance)
                window.contentView = host
                // Captured from the window server rather than drawn into a
                // bitmap, which leaves out blurs and bends rotated cards.
                // Kept under the desktop picture so it never shows.
                window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
                window.orderFrontRegardless()
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(2))
                let capture = Process()
                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", folder.appendingPathComponent("\(name)-\(look).png").path]
                try? capture.run()
                capture.waitUntilExit()
                window.orderOut(nil)
            }
        }
    }
}
#endif
