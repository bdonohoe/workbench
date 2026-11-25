import BenchKit
import Foundation

/// The pages Claude has published for each project, found in the project's
/// Claude Code transcripts, newest update first.
@Observable
final class ArtifactLibrary {
    static let shared = ArtifactLibrary()

    /// By project path, since worktrees and remote requests come by path.
    private(set) var links: [String: [ArtifactLink]] = [:]
    @ObservationIgnored private var loading: Set<String> = []
    @ObservationIgnored private var loaded: [String: Date] = [:]

    func links(for project: Project) -> [ArtifactLink] { links[project.path] ?? [] }

    /// Reads the project's transcripts again, unless it did in the last
    /// few seconds. Only what's new in each transcript gets read.
    func refresh(path: String) {
        guard !loading.contains(path), Date().timeIntervalSince(loaded[path] ?? .distantPast) > 3 else { return }
        loading.insert(path)
        Task {
            let found = await Self.load(path: path)
            loading.remove(path)
            loaded[path] = .now
            if links[path] != found { links[path] = found }
        }
    }

    /// The project's artifacts, read now.
    func load(path: String) async -> [ArtifactLink] {
        let found = await Self.load(path: path)
        loaded[path] = .now
        if links[path] != found { links[path] = found }
        return found
    }

    nonisolated private static func load(path: String) async -> [ArtifactLink] {
        let titles = Dictionary(await SessionHistory.load(projectPath: path).map { session in
            (session.id, session.title ?? session.firstPrompt.map { $0.count > 60 ? String($0.prefix(59)) + "…" : $0 })
        }, uniquingKeysWith: { first, _ in first })
        return await Task.detached(priority: .utility) {
            let files = SessionHistory.files(forProject: path).map(\.file)
            var byURL: [String: ArtifactLink] = [:]
            /// The best name seen for each page: highest rank, then newest.
            var bestTitles: [String: (title: String, rank: Int, at: Date)] = [:]
            for file in files {
                let sessionID = file.deletingPathExtension().lastPathComponent
                for found in scanner.links(in: file) {
                    var link = found.link
                    link.sessionID = sessionID
                    link.sessionTitle = titles[sessionID] ?? nil
                    if !link.title.isEmpty, let best = bestTitles[link.url] {
                        if found.rank > best.rank || (found.rank == best.rank && link.updated >= best.at) {
                            bestTitles[link.url] = (link.title, found.rank, link.updated)
                        }
                    } else if !link.title.isEmpty {
                        bestTitles[link.url] = (link.title, found.rank, link.updated)
                    }
                    if let existing = byURL[link.url] {
                        // Keep the newest publish, with the best title and version seen.
                        let newer = link.updated >= existing.updated ? link : existing
                        var merged = newer
                        if merged.title.isEmpty { merged.title = existing.title.isEmpty ? link.title : existing.title }
                        merged.version = [link.version, existing.version].compactMap { $0 }.max()
                        merged.icon = newer.icon ?? existing.icon ?? link.icon
                        byURL[link.url] = merged
                    } else {
                        byURL[link.url] = link
                    }
                }
            }
            for (url, best) in bestTitles { byURL[url]?.title = best.title }
            return byURL.values
                .map { link in
                    var link = link
                    if link.title.isEmpty { link.title = "Untitled page" }
                    return link
                }
                .sorted { $0.updated > $1.updated }
        }.value
    }

    nonisolated private static let scanner = Scanner()

    /// Reads each transcript once, then only the lines added since.
    nonisolated private struct Found: Sendable {
        var link: ArtifactLink
        /// How sure the title is; see `ArtifactPublish.titleGuess`.
        var rank: Int
    }

    nonisolated private final class Scanner: @unchecked Sendable {
        private struct Entry {
            var offset: UInt64
            var links: [Found]
            /// Publish calls seen but not answered yet, by tool use id: their titles.
            var pending: [String: (title: String, rank: Int)]
        }
        private let lock = NSLock()
        private var entries: [String: Entry] = [:]

        func links(in file: URL) -> [Found] {
            let size = UInt64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            lock.lock()
            var entry = entries[file.path] ?? Entry(offset: 0, links: [], pending: [:])
            lock.unlock()
            // A transcript that shrank was rewritten; start over.
            if size < entry.offset { entry = Entry(offset: 0, links: [], pending: [:]) }
            guard size > entry.offset, let handle = FileHandle(forReadingAtPath: file.path) else { return entry.links }
            defer { try? handle.close() }
            try? handle.seek(toOffset: entry.offset)
            guard let data = try? handle.readToEnd(), !data.isEmpty else { return entry.links }
            // Only whole lines; a line still being written waits for next time.
            guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return entry.links }
            let complete = data[data.startIndex...lastNewline]
            entry.offset += UInt64(complete.count)
            for line in complete.split(separator: UInt8(ascii: "\n")) {
                read(Data(line), into: &entry)
            }
            lock.lock()
            entries[file.path] = entry
            lock.unlock()
            return entry.links
        }

        private static let markers = ["claude.ai/", "\"Artifact\"", "artifacts__"].map { Data($0.utf8) }

        private func read(_ line: Data, into entry: inout Entry) {
            // Lines without a time are copies (a subagent's, a hook's) of
            // ones that have one.
            guard Self.markers.contains(where: { line.range(of: $0) != nil }),
                  let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  json["isSidechain"] as? Bool != true,
                  let at = (json["timestamp"] as? String).flatMap(Self.date),
                  let message = json["message"] as? [String: Any],
                  let blocks = message["content"] as? [[String: Any]] else { return }
            for block in blocks {
                switch block["type"] as? String {
                case "tool_use":
                    let name = block["name"] as? String ?? ""
                    let input = block["input"] as? [String: Any] ?? [:]
                    guard ArtifactPublish.isPublish(tool: name, input: input), let id = block["id"] as? String else { continue }
                    entry.pending[id] = ArtifactPublish.titleGuess(tool: name, input: input) ?? ("", -1)
                case "tool_result":
                    guard let id = block["tool_use_id"] as? String, let guess = entry.pending.removeValue(forKey: id),
                          block["is_error"] as? Bool != true else { continue }
                    let text: String
                    if let string = block["content"] as? String {
                        text = string
                    } else {
                        text = (block["content"] as? [[String: Any]] ?? [])
                            .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                            .joined(separator: "\n")
                    }
                    guard var link = ArtifactPublish.link(fromResult: text) else { continue }
                    let rank = link.title.isEmpty ? guess.rank : 3
                    if link.title.isEmpty { link.title = guess.title }
                    if link.updated == .distantPast { link.updated = at }
                    entry.links.append(Found(link: link, rank: rank))
                default:
                    continue
                }
            }
        }

        private static func date(_ text: String) -> Date? {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
        }
    }
}
