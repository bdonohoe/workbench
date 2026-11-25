import BenchKit
import Foundation

/// The slash commands Claude Code offers in a project: its own, yours and
/// the project's from `.claude/commands`, skills, and enabled plugins'.
@Observable
final class SlashCommandLibrary {
    static let shared = SlashCommandLibrary()

    private(set) var commands: [String: [SlashCommand]] = [:]
    @ObservationIgnored private var loaded: [String: Date] = [:]
    @ObservationIgnored private var loading: Set<String> = []

    /// What's known for a project now, and a fresh look if the last one is
    /// more than half a minute old.
    func commands(forProject path: String) -> [SlashCommand] {
        refresh(path: path)
        return commands[path] ?? SlashCommand.builtIn
    }

    func refresh(path: String) {
        guard !loading.contains(path), Date().timeIntervalSince(loaded[path] ?? .distantPast) > 30 else { return }
        loading.insert(path)
        Task {
            let found = await load(path: path)
            loading.remove(path)
            if commands[path] != found { commands[path] = found }
        }
    }

    func load(path: String) async -> [SlashCommand] {
        let found = await Task.detached(priority: .utility) { Self.find(projectPath: path) }.value
        loaded[path] = .now
        if commands[path] != found { commands[path] = found }
        return found
    }

    nonisolated private static func find(projectPath: String) -> [SlashCommand] {
        let home = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        return find(projectPath: projectPath, home: home)
    }

    nonisolated static func find(projectPath: String, home: URL) -> [SlashCommand] {
        let project = URL(fileURLWithPath: projectPath).appendingPathComponent(".claude")

        // Later ones replace earlier ones with the same name.
        var byName: [String: SlashCommand] = [:]
        for command in SlashCommand.builtIn { byName[command.name] = command }
        for command in pluginCommands(home: home, project: project, projectPath: projectPath) { byName[command.name] = command }
        for command in commands(in: home.appendingPathComponent("commands"), source: .user) { byName[command.name] = command }
        for command in skills(in: home.appendingPathComponent("skills"), source: .user) { byName[command.name] = command }
        for command in commands(in: project.appendingPathComponent("commands"), source: .project) { byName[command.name] = command }
        for command in skills(in: project.appendingPathComponent("skills"), source: .project) { byName[command.name] = command }
        return byName.values.sorted { $0.name < $1.name }
    }

    /// `name.md` files, with folders becoming "folder:name".
    nonisolated private static func commands(in folder: URL, source: SlashCommand.Source, prefix: String = "") -> [SlashCommand] {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil,
                                                              options: [.skipsHiddenFiles]) else { return [] }
        var found: [SlashCommand] = []
        for case let file as URL in enumerator where file.pathExtension == "md" {
            let relative = file.path.dropFirst(folder.path.count + 1).dropLast(3)
            let name = prefix + relative.replacingOccurrences(of: "/", with: ":")
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let meta = frontmatter(text)
            found.append(SlashCommand(name: name, description: meta.fields["description"] ?? firstLine(meta.body) ?? "",
                                      argumentHint: meta.fields["argument-hint"], source: source))
        }
        return found
    }

    /// Folders with a SKILL.md, named by its frontmatter or the folder.
    nonisolated private static func skills(in folder: URL, source: SlashCommand.Source, prefix: String = "") -> [SlashCommand] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                                    options: [.skipsHiddenFiles])) ?? []
        return folders.compactMap { skill(at: $0, source: source, prefix: prefix) }
    }

    /// The skill in a folder with a SKILL.md, unless it's one only Claude
    /// reaches for.
    nonisolated private static func skill(at folder: URL, source: SlashCommand.Source, prefix: String) -> SlashCommand? {
        let file = folder.resolvingSymlinksInPath().appendingPathComponent("SKILL.md")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let meta = frontmatter(text)
        // Skills only Claude reaches for aren't commands you can type.
        guard meta.fields["user-invocable"]?.lowercased() != "false" else { return nil }
        let name = meta.fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? folder.lastPathComponent
        return SlashCommand(name: prefix + name, description: meta.fields["description"] ?? firstLine(meta.body) ?? "",
                            argumentHint: meta.fields["argument-hint"], source: source)
    }

    /// Commands and skills from the plugins turned on in your settings or
    /// the project's, as "plugin:name".
    nonisolated private static func pluginCommands(home: URL, project: URL, projectPath: String) -> [SlashCommand] {
        var enabled: [String: Bool] = [:]
        for settings in [home.appendingPathComponent("settings.json"),
                         project.appendingPathComponent("settings.json"),
                         project.appendingPathComponent("settings.local.json")] {
            guard let json = jsonObject(at: settings),
                  let plugins = json["enabledPlugins"] as? [String: Bool] else { continue }
            enabled.merge(plugins) { _, new in new }
        }
        guard let json = jsonObject(at: home.appendingPathComponent("plugins/installed_plugins.json")),
              let installed = json["plugins"] as? [String: [[String: Any]]] else { return [] }
        let marketplaces = jsonObject(at: home.appendingPathComponent("plugins/known_marketplaces.json")) ?? [:]
        var found: [SlashCommand] = []
        for (key, installs) in installed where enabled[key] == true {
            guard let path = install(of: installs, for: projectPath)?["installPath"] as? String else { continue }
            let parts = key.split(separator: "@", maxSplits: 1).map(String.init)
            let plugin = parts.first ?? key
            let prefix = plugin + ":"
            let root = URL(fileURLWithPath: path)
            // Its own folders, plus any it names in its manifest or its
            // marketplace's listing, which is how a plugin that's only a set
            // of skills usually points at them.
            var commandPaths = [root.appendingPathComponent("commands")]
            var skillPaths = [root.appendingPathComponent("skills")]
            var listings: [[String: Any]] = []
            if let manifest = jsonObject(at: root.appendingPathComponent(".claude-plugin/plugin.json")) {
                listings.append(manifest)
            }
            if parts.count == 2, let entry = marketplaceEntry(plugin: plugin, marketplace: parts[1], known: marketplaces) {
                listings.append(entry)
            }
            for listing in listings {
                commandPaths += componentPaths(listing["commands"], root: root)
                skillPaths += componentPaths(listing["skills"], root: root)
            }
            var seen: Set<String> = []
            for url in commandPaths where seen.insert("c " + url.standardizedFileURL.path).inserted {
                if url.pathExtension == "md" {
                    found += commands(file: url, source: .plugin, prefix: prefix)
                } else {
                    found += commands(in: url, source: .plugin, prefix: prefix)
                }
            }
            for url in skillPaths where seen.insert("s " + url.standardizedFileURL.path).inserted {
                // A path to one skill, or to a folder of them.
                if let one = skill(at: url, source: .plugin, prefix: prefix) {
                    found.append(one)
                } else {
                    found += skills(in: url, source: .plugin, prefix: prefix)
                }
            }
        }
        return found
    }

    /// The install that applies here: the one made for this project, or
    /// failing that one made for you, or the latest.
    nonisolated private static func install(of installs: [[String: Any]], for projectPath: String) -> [String: Any]? {
        let here = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        return installs.last { ($0["projectPath"] as? String).map { URL(fileURLWithPath: $0).standardizedFileURL.path } == here }
            ?? installs.last { ($0["scope"] as? String) == "user" }
            ?? installs.last
    }

    /// A plugin's entry in its marketplace's listing.
    nonisolated private static func marketplaceEntry(plugin: String, marketplace: String,
                                                     known: [String: Any]) -> [String: Any]? {
        guard let info = known[marketplace] as? [String: Any],
              let location = info["installLocation"] as? String,
              let listing = jsonObject(at: URL(fileURLWithPath: location).appendingPathComponent(".claude-plugin/marketplace.json")),
              let plugins = listing["plugins"] as? [[String: Any]] else { return nil }
        return plugins.first { ($0["name"] as? String) == plugin }
    }

    /// A manifest's "./path" or ["./path", ...], under the plugin's folder.
    nonisolated private static func componentPaths(_ value: Any?, root: URL) -> [URL] {
        let paths = (value as? [String]) ?? (value as? String).map { [$0] } ?? []
        return paths.map { root.appendingPathComponent($0).standardizedFileURL }
    }

    /// One command file named in a manifest.
    nonisolated private static func commands(file: URL, source: SlashCommand.Source, prefix: String) -> [SlashCommand] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let meta = frontmatter(text)
        return [SlashCommand(name: prefix + file.deletingPathExtension().lastPathComponent,
                             description: meta.fields["description"] ?? firstLine(meta.body) ?? "",
                             argumentHint: meta.fields["argument-hint"], source: source)]
    }

    nonisolated private static func jsonObject(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The `key: value` lines between a file's opening `---` lines, and
    /// what follows. A value of `>` or `|` takes the indented lines below.
    nonisolated private static func frontmatter(_ text: String) -> (fields: [String: String], body: String) {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return ([:], text)
        }
        var fields: [String: String] = [:]
        var index = 1
        while index < end {
            let line = lines[index]
            index += 1
            guard !line.hasPrefix(" "), let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if [">", "|", ">-", "|-"].contains(value) {
                var parts: [String] = []
                while index < end, lines[index].hasPrefix(" ") || lines[index].isEmpty {
                    parts.append(lines[index].trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                value = parts.filter { !$0.isEmpty }.joined(separator: " ")
            }
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
            }
            fields[key] = value
        }
        return (fields, lines[(end + 1)...].joined(separator: "\n"))
    }

    nonisolated private static func firstLine(_ body: String) -> String? {
        body.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "#"))) }
            .first { !$0.isEmpty }
    }
}
