import Foundation
import Observation
import SwiftUI

/// A one-click tab that runs a command, like `ssh my-server` or
/// `make watch`. Shown in the tab bar and the + menu.
struct TabShortcut: Codable, Identifiable, Hashable {
    var id = UUID()
    /// The button's label.
    var name: String
    var command: String
    /// An SF Symbol for the button.
    var symbol = "terminal"
    /// No longer shown anywhere since the + menu took over the tab bar
    /// buttons. Kept so saved shortcuts and older iPhones still decode.
    var showsInTabBar = true
    /// Only show it in projects that contain this file or folder, like
    /// "package.json" or "Makefile". Empty means every project.
    var requiredFile = ""
    /// Only show it in this project. Nil means every project.
    var projectID: UUID?
    /// Switch to a tab still running this command instead of opening
    /// another, which suits dev servers.
    var reusesRunningTab = false

    func applies(to project: Project) -> Bool {
        if let projectID, projectID != project.id, projectID != project.parentID { return false }
        let file = requiredFile.trimmingCharacters(in: .whitespaces)
        if !file.isEmpty, !FileManager.default.fileExists(atPath: project.url.appendingPathComponent(file).path) { return false }
        return true
    }

    /// Symbols offered in the editor.
    static let symbols = ["terminal", "play.fill", "network", "server.rack", "hammer.fill", "testtube.2",
                          "shippingbox.fill", "arrow.triangle.2.circlepath", "doc.text.magnifyingglass",
                          "cylinder.split.1x2.fill", "globe", "bolt.fill"]
}

/// Your tab shortcuts, saved in Bench's folder.
@Observable
final class TabShortcuts {
    private(set) var all: [TabShortcut] = []

    /// Shows a dev server button in JavaScript projects that have a dev script.
    var showsDevButton: Bool {
        didSet { UserDefaults.standard.set(showsDevButton, forKey: "showsDevButton") }
    }

    private static let file = BenchPaths.support.appendingPathComponent("shortcuts.json")

    init() {
        showsDevButton = UserDefaults.standard.object(forKey: "showsDevButton") as? Bool ?? true
        if let data = try? Data(contentsOf: Self.file) {
            if let saved = try? JSONDecoder().decode(LossyArray<TabShortcut>.self, from: data) {
                all = saved.wrappedValue
            } else {
                BenchPaths.setAside(Self.file)
            }
        }
    }

    func shortcuts(for project: Project) -> [TabShortcut] {
        all.filter { $0.applies(to: project) }
    }

    func save(_ shortcut: TabShortcut) {
        if let index = all.firstIndex(where: { $0.id == shortcut.id }) {
            all[index] = shortcut
        } else {
            all.append(shortcut)
        }
        write()
    }

    func delete(_ id: UUID) {
        all.removeAll { $0.id == id }
        write()
    }

    func move(from source: IndexSet, to destination: Int) {
        all.move(fromOffsets: source, toOffset: destination)
        write()
    }

    private func write() {
        do {
            try FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(all).write(to: Self.file, options: .atomic)
        } catch {
            NSLog("Bench: couldn't save shortcuts: \(error)")
        }
    }
}

/// How a JavaScript project runs things, read from its lockfile and
/// package.json.
enum PackageManager: String {
    case bun, pnpm, yarn, npm

    /// The project's package manager, or nil when it has no package.json.
    static func detect(in folder: URL) -> PackageManager? {
        let fileManager = FileManager.default
        func has(_ name: String) -> Bool { fileManager.fileExists(atPath: folder.appendingPathComponent(name).path) }
        guard has("package.json") else { return nil }
        if has("bun.lock") || has("bun.lockb") { return .bun }
        if has("pnpm-lock.yaml") { return .pnpm }
        if has("yarn.lock") { return .yarn }
        return .npm
    }

    /// "bun run dev", when package.json has a dev script.
    static func devCommand(in folder: URL) -> String? {
        guard let manager = detect(in: folder),
              let data = try? Data(contentsOf: folder.appendingPathComponent("package.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = json["scripts"] as? [String: Any], scripts["dev"] != nil else { return nil }
        return "\(manager.rawValue) run dev"
    }

    /// "pnpm install"
    var installCommand: String { "\(rawValue) install" }
}
