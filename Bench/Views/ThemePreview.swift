import AppKit
import BenchKit
import SwiftUI

#if DEBUG
/// The New Agent sheet and the checklist drawn to PNGs in the built-in
/// theme the launch arguments pick (`-themeSource builtIn
/// -builtInLightTheme sea-glass`), or the plain look with `-themeSource
/// system`. BENCH_RENDER_THEME=<folder>.
enum ThemePreview {
    static func render(to folder: URL) {
        _ = NSApplication.shared
        let store = AppStore()
        let terminals = TerminalManager(store: store)
        guard let parent = store.projects.first(where: { !$0.isWorktree }) else { return }
        let theme = TerminalTheme.shared
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let dark = appearance == .darkAqua
            if let builtIn = theme.activeBuiltInTheme(dark: dark) {
                func color(_ rgb: TerminalColors.RGB) -> NSColor {
                    NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
                }
                theme.setForTesting(background: color(builtIn.background), foreground: color(builtIn.foreground),
                                    ansi: builtIn.palette.map(color))
            }
            let suffix = theme.activeBuiltInTheme(dark: dark)?.id ?? "system-\(name)"
            let sheet = NewAgentSheet(parent: parent)
                .environment(store).environment(terminals)
                .background(theme.sheetBackground)
            draw(sheet, size: NSSize(width: 480, height: 420), appearance: appearance,
                 to: folder.appendingPathComponent("new-agent-\(suffix).png"))

            let started = Date().addingTimeInterval(-59)
            let items = [
                ChecklistItem(id: "1", title: "Keep the full plan text when parsing transcripts", status: .completed),
                ChecklistItem(id: "2", title: "Plan card in the chat with Show full plan", status: .completed),
                ChecklistItem(id: "3", title: "Read the plan button on the approval card", status: .completed),
                ChecklistItem(id: "4", title: "Fix dead file links for files outside the project", status: .inProgress, startedAt: started),
                ChecklistItem(id: "5", title: "Build and run the tests", status: .pending),
            ]
            let checklist = ChecklistSection(items: items)
                .frame(width: 320)
                .environment(\.companionPalette, theme.chatPalette)
                .background(theme.panel ?? Color(nsColor: .windowBackgroundColor))
            draw(checklist, size: NSSize(width: 320, height: 200), appearance: appearance,
                 to: folder.appendingPathComponent("checklist-\(suffix).png"))
        }
    }

    /// The sidebar's four states (working, needs you, done, notification)
    /// in every built-in theme, on one sheet, to compare how the working
    /// color lands in each. BENCH_RENDER_ACTIVITY_THEMES=<folder>, with
    /// `-themeSource ghostty` so the theme's cursor stands in as its accent.
    static func renderActivity(to folder: URL) {
        _ = NSApplication.shared
        let theme = TerminalTheme.shared
        func color(_ rgb: TerminalColors.RGB) -> NSColor {
            NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
        }
        var cells: [NSBitmapImageRep] = []
        for builtIn in BuiltInTheme.all {
            theme.setForTesting(background: color(builtIn.background), foreground: color(builtIn.foreground),
                                ansi: builtIn.palette.map(color), cursor: color(builtIn.cursor))
            let rows: [(String, TabActivity)] = [("Working", .working), ("Needs you", .waiting),
                                                 ("Done", .done), ("Notification", .attention)]
            let cell = VStack(alignment: .leading, spacing: 3) {
                Text(builtIn.name).font(.ui(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.bottom, 2)
                ForEach(rows, id: \.0) { row in
                    HStack(spacing: 7) {
                        ActivityIndicator(activity: row.1, size: 10)
                        Text(row.0).font(.ui(size: 12))
                        Spacer()
                    }
                    .padding(.horizontal, 8).frame(height: 24)
                    .background { ActivityBackground(activity: row.1) }
                }
                // A busy row's timer and checklist, which should match the working tint.
                VStack(alignment: .leading, spacing: 4) {
                    ActiveTimerLine(since: Date().addingTimeInterval(-526), action: "Building", activity: .working)
                    ChecklistStepsBar(items: (0..<4).map { i in
                        ChecklistItem(id: "\(i)", title: "Step \(i)",
                                      status: i < 2 ? .completed : i == 2 ? .inProgress : .pending)
                    }, activity: .working)
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background { ActivityBackground(activity: .working) }
            }
            .padding(10).frame(width: 200)
            .background(theme.panel ?? Color(nsColor: .windowBackgroundColor))
            .environment(\.companionPalette, theme.sidebarPalette)
            if let rep = image(cell, appearance: builtIn.isDark ? .darkAqua : .aqua) { cells.append(rep) }
        }
        guard let first = cells.first else { return }
        let columns = 6, size = NSSize(width: first.pixelsWide, height: first.pixelsHigh)
        let rowsCount = (cells.count + columns - 1) / columns
        guard let sheet = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * columns,
                                           pixelsHigh: Int(size.height) * rowsCount, bitsPerSample: 8,
                                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
        for (index, cell) in cells.enumerated() {
            let x = CGFloat(index % columns) * size.width
            let y = CGFloat(rowsCount - 1 - index / columns) * size.height
            cell.draw(in: NSRect(origin: NSPoint(x: x, y: y), size: size))
        }
        NSGraphicsContext.restoreGraphicsState()
        try? sheet.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("activity-themes.png"))
    }

    private static func image(_ view: some View, appearance: NSAppearance.Name) -> NSBitmapImageRep? {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.setFrameSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    private static func draw(_ view: some View, size: NSSize, appearance: NSAppearance.Name, to file: URL) {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.setFrameSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        host.setFrameSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
    }
}
#endif
