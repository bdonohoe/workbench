import Foundation

/// What the phone last heard from a Mac, kept on disk so the projects
/// still show after a cold launch while the Mac sleeps.
public struct SavedMac: Codable, Sendable {
    public var snapshot: ProjectsSnapshot
    public var features: Set<String>
    public var macName: String?
    public var savedAt: Date

    public init(snapshot: ProjectsSnapshot, features: Set<String>, macName: String?, savedAt: Date) {
        self.snapshot = snapshot
        self.features = features
        self.macName = macName
        self.savedAt = savedAt
    }
}

extension ProjectsSnapshot {
    /// The same projects with no tabs. Tabs go stale as soon as the Mac
    /// is out of reach, so a saved list leaves them out.
    public var withoutSessions: ProjectsSnapshot {
        var copy = self
        for index in copy.projects.indices { copy.projects[index].sessions = [] }
        return copy
    }
}

/// One file per Mac in a folder. The file name is a hash of the host, so
/// the Mac's name isn't spelled out on disk.
public struct SnapshotCache: Sendable {
    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    /// Application Support/SavedMacs.
    public static var standard: SnapshotCache {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return SnapshotCache(folder: support.appendingPathComponent("SavedMacs", isDirectory: true))
    }

    func file(for host: String) -> URL {
        folder.appendingPathComponent(NotificationSeal.opaque(host) + ".json")
    }

    public func save(_ saved: SavedMac, host: String) {
        var saved = saved
        saved.snapshot = saved.snapshot.withoutSessions
        guard let data = try? CompanionCoding.encoder.encode(saved) else { return }
        LocalFolder.make(folder)
        try? data.write(to: file(for: host), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    public func load(host: String) -> SavedMac? {
        guard let data = try? Data(contentsOf: file(for: host)) else { return nil }
        return try? CompanionCoding.decoder.decode(SavedMac.self, from: data)
    }

    public func remove(host: String) {
        try? FileManager.default.removeItem(at: file(for: host))
    }

    /// For a Mac that's now at a different host: its saved list goes with
    /// it, replacing anything the new host had.
    public func move(from old: String, to new: String) {
        guard old != new, FileManager.default.fileExists(atPath: file(for: old).path) else { return }
        try? FileManager.default.removeItem(at: file(for: new))
        try? FileManager.default.moveItem(at: file(for: old), to: file(for: new))
    }
}

/// A folder of the phone's own files that stays on the phone: it's left
/// out of iCloud and device backups.
enum LocalFolder {
    static func make(_ folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = folder
        try? url.setResourceValues(values)
    }
}
