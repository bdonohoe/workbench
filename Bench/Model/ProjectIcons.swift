import AppKit
import BenchKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Finds and caches each project's sidebar icon.
///
/// A project's icon is `.bench/icon.png` in its folder (any common image
/// format works). That's the file the "Ask Claude to Set Icon" prompt asks
/// Claude to write. Without one, Bench looks for an app icon or web logo.
@Observable
final class ProjectIcons {
    private(set) var images: [UUID: NSImage] = [:]
    private var tints: [UUID: Color] = [:]
    private var sources: [UUID: Source] = [:]
    @ObservationIgnored private var roots: [UUID: URL] = [:]

    nonisolated static let folder = ".bench"
    nonisolated static let extensions = ["png", "jpg", "jpeg", "heic", "webp", "tiff", "gif", "icns", "svg", "pdf"]

    static let claudePrompt = """
        Find or make a square icon for this project and save it as .bench/icon.png in the project root. \
        Good sources are the app icon (an AppIcon.appiconset image, or a rendered export of a .icon bundle), \
        a logo, or a favicon. If there is nothing usable, design a simple one. \
        It shows at about 28 points in the Workbench sidebar, so 256 by 256 pixels is ideal.
        """

    private struct Source: Equatable {
        var path: String
        var modified: Date?
    }

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            // Pick up icons changed while Bench was in the background.
            MainActor.assumeIsolated {
                guard let self else { return }
                for (id, root) in self.roots { self.reload(id, root: root) }
            }
        }
    }

    func image(for project: Project) -> NSImage? { images[project.id] }

    /// The color the project's icon is mostly made of, for its start
    /// page's glow: from the image, or from the lettered tile when it has
    /// none. Nil for a grey icon, which has no color to give.
    func tint(for project: Project) -> Color? {
        guard images[project.id] != nil else { return IconTint.tileColor(for: project.repoName) }
        return tints[project.id]
    }

    /// Looks for the project's icon off the main thread and updates it if it changed.
    func reload(_ project: Project) {
        reload(project.id, root: project.url)
    }

    private func reload(_ id: UUID, root: URL) {
        roots[id] = root
        Task { [weak self] in
            let found = await Task.detached(priority: .utility) { Self.findIcon(in: root) }.value
            guard let self else { return }
            let source = found.map { Source(path: $0.path, modified: Self.modified($0)) }
            guard source != sources[id] || (source != nil && images[id] == nil) else { return }
            sources[id] = source
            let image = found.flatMap { NSImage(contentsOf: $0) }
            images[id] = image
            tints[id] = image.flatMap(IconTint.color(of:))
        }
    }

    // MARK: Setting

    /// Copies an image into the project's `.bench` folder as its icon.
    func setIcon(from file: URL, for project: Project) throws {
        let folder = project.url.appendingPathComponent(Self.folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try removeIconFiles(in: folder)
        let ext = file.pathExtension.lowercased()
        try FileManager.default.copyItem(at: file, to: folder.appendingPathComponent("icon.\(ext.isEmpty ? "png" : ext)"))
        reload(project)
    }

    /// Saves an image sent from another Mac as the project's icon.
    func setIcon(data: Data, fileExtension: String?, for project: Project) throws {
        let ext = fileExtension?.lowercased() ?? "png"
        guard Self.extensions.contains(ext), NSImage(data: data) != nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("icon-\(UUID().uuidString).\(ext)")
        try data.write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        try setIcon(from: temp, for: project)
    }

    /// Moves the project's `.bench` icon to the Trash, going back to the automatic one.
    func resetIcon(for project: Project) throws {
        try removeIconFiles(in: project.url.appendingPathComponent(Self.folder))
        reload(project)
    }

    func hasCustomIcon(_ project: Project) -> Bool {
        sources[project.id]?.path.contains("/\(Self.folder)/") == true
    }

    private func removeIconFiles(in folder: URL) throws {
        for ext in Self.extensions {
            let url = folder.appendingPathComponent("icon.\(ext)")
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
        }
    }

    static func presentPicker(for project: Project, icons: ProjectIcons) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose an icon for \(project.name)"
        panel.prompt = "Use as Icon"
        panel.directoryURL = project.url
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try icons.setIcon(from: url, for: project)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    // MARK: Finding

    nonisolated private static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    nonisolated static func findIcon(in root: URL) -> URL? {
        let fm = FileManager.default
        let folder = root.appendingPathComponent(folder)
        for ext in extensions {
            let url = folder.appendingPathComponent("icon.\(ext)")
            if fm.fileExists(atPath: url.path) { return url }
        }
        return appIcon(in: root) ?? webIcon(in: root)
    }

    nonisolated private static let skippedFolders: Set<String> = [
        "node_modules", ".git", "DerivedData", "build", "Build", "Pods", "vendor", ".next", "dist",
        ".build", "versions", "Carthage", "Tests", "UITests",
    ]

    /// The largest image in an Xcode AppIcon set, a few folders deep.
    nonisolated private static func appIcon(in root: URL) -> URL? {
        var best: (url: URL, pixels: Int)?
        var queue: [(URL, Int)] = [(root, 0)]
        let fm = FileManager.default
        while !queue.isEmpty {
            let (dir, depth) = queue.removeFirst()
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for item in items {
                let name = item.lastPathComponent
                guard (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                if name.hasSuffix(".appiconset") {
                    for image in (try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? []
                    where ["png", "jpg", "jpeg"].contains(image.pathExtension.lowercased()) {
                        let pixels = NSImageRep(contentsOf: image).map { $0.pixelsWide } ?? 0
                        if pixels > (best?.pixels ?? 0) { best = (image, pixels) }
                    }
                } else if depth < 4, !skippedFolders.contains(name), !name.hasSuffix(".xcodeproj"), !name.hasSuffix(".icon") {
                    queue.append((item, depth + 1))
                }
            }
            // Prefer the app's icon over a widget's, which sits deeper.
            if best != nil, queue.first.map({ $0.1 > depth }) == true { break }
        }
        return best?.url
    }

    /// Common web project icon spots.
    nonisolated private static func webIcon(in root: URL) -> URL? {
        let folders = ["", "public", "static", "assets", "src/app", "app", "images"]
        let names = ["apple-touch-icon.png", "icon.png", "logo.png", "favicon.png", "logo.svg", "favicon.svg", "icon.svg"]
        for folder in folders {
            for name in names {
                let url = root.appendingPathComponent(folder).appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }
}

extension IconTint {
    /// An icon's main color, made fit to light a page: colorful enough to
    /// read as a color and neither too dark nor too pale to show as a soft
    /// wash on a light or a dark canvas. Nil for a grey icon.
    static func color(of image: NSImage) -> Color? {
        guard let pixels = pixels(of: image), let found = dominant(rgba: pixels) else { return nil }
        let color = NSColor(srgbRed: found.red, green: found.green, blue: found.blue, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return Color(hue: hue, saturation: min(max(saturation, 0.5), 0.85), brightness: min(max(brightness, 0.6), 0.92))
    }

    /// The same, for an icon another Mac sent. Kept by the data's hash,
    /// since views ask on every redraw.
    @MainActor static func color(ofIcon data: Data) -> Color? {
        if let known = dataColors[data.hashValue] { return known }
        let color = NSImage(data: data).flatMap(color(of:))
        dataColors[data.hashValue] = .some(color)
        return color
    }

    @MainActor private static var dataColors: [Int: Color?] = [:]

    /// The color of the lettered tile a project without an icon gets.
    static func tileColor(for repoName: String) -> Color {
        Color(hue: tileHue(for: repoName), saturation: 0.6, brightness: 0.82)
    }

    /// The image scaled down to a few hundred pixels, as plain RGBA.
    private static func pixels(of image: NSImage, side: Int = 24) -> [UInt8]? {
        var rect = CGRect(x: 0, y: 0, width: side, height: side)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var data = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        // The context multiplies color by alpha. Undo that, so a soft edge
        // keeps its color.
        for index in stride(from: 0, to: data.count, by: 4) {
            let alpha = Int(data[index + 3])
            guard alpha > 0, alpha < 255 else { continue }
            for channel in 0..<3 {
                data[index + channel] = UInt8(min(255, Int(data[index + channel]) * 255 / alpha))
            }
        }
        return data
    }
}
