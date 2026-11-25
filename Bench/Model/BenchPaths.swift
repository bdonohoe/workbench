import Foundation

enum BenchPaths {
    /// What follows `me.birchtree.Bench.` in this copy's bundle id, such as
    /// `beta` for the second copy `make install-beta` puts in Applications.
    /// Nil for the real app. A copy with a suffix keeps its own settings,
    /// listens on its own port and never checks for updates, so it can run
    /// beside the real one.
    nonisolated static let instanceSuffix: String? = {
        guard let id = Bundle.main.bundleIdentifier, id.hasPrefix("me.birchtree.Bench."),
              id.count > "me.birchtree.Bench.".count else { return nil }
        return String(id.dropFirst("me.birchtree.Bench.".count))
    }()

    /// True for a copy of Workbench that isn't the one Sparkle updates.
    nonisolated static var isSecondaryInstance: Bool { instanceSuffix != nil }

    /// Bench's folder in Application Support, where everything it keeps
    /// lives: `Bench` for the real app, `Bench-beta` for a copy whose
    /// bundle id ends in `.beta`. In debug builds, BENCH_SUPPORT_DIR points
    /// a second copy of Bench at a folder of its own, so it can be tried
    /// without touching the real one.
    nonisolated static let support: URL = {
        #if DEBUG
        if let dir = ProcessInfo.processInfo.environment["BENCH_SUPPORT_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir)
        }
        #endif
        let name = instanceSuffix.map { "Bench-\($0)" } ?? "Bench"
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name)
    }()

    /// Moves a saved file Bench couldn't read out of the way, to
    /// `<name>.broken-<date>`, so a later save can't write over it and
    /// what was in it can still be recovered. Returns where it went.
    @discardableResult
    nonisolated static func setAside(_ file: URL) -> URL? {
        let stamp = ISO8601DateFormatter().string(from: .now)
            .replacingOccurrences(of: ":", with: "-")
        let destination = file.appendingPathExtension("broken-\(stamp)")
        do {
            try FileManager.default.moveItem(at: file, to: destination)
            NSLog("Bench: couldn't read \(file.lastPathComponent); kept it at \(destination.path)")
            return destination
        } catch {
            NSLog("Bench: couldn't read \(file.lastPathComponent), and couldn't set it aside: \(error)")
            return nil
        }
    }
}
