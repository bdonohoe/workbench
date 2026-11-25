import Foundation
import Testing
@testable import Bench

/// The chat view's slash menu finds plugin skills wherever the plugin says
/// they are, not only in a `skills` folder at its top.
struct SlashCommandLibraryTests {
    private let fm = FileManager.default

    private func folder() throws -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent("bench-slash-\(UUID().uuidString)")
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func skill(_ name: String, in folder: URL) throws {
        try write("---\nname: \(name)\ndescription: Does \(name)\n---\nBody\n",
                  to: folder.appendingPathComponent(name).appendingPathComponent("SKILL.md"))
    }

    @Test func findsSkillsAPluginListsInItsMarketplaceAndManifest() throws {
        let base = try folder()
        let home = base.appendingPathComponent("claude")
        let project = base.appendingPathComponent("project")
        let market = base.appendingPathComponent("my-market")
        let plugin = home.appendingPathComponent("plugins/cache/my-market/team-skills/1.0.0")
        let other = home.appendingPathComponent("plugins/cache/my-market/team-skills/0.9.0")

        // Skills at the plugin's top, named only in the marketplace listing,
        // and one more named in its own manifest.
        try skill("pr-review", in: plugin)
        try skill("deploy", in: plugin.appendingPathComponent("extra"))
        try write(#"{"name": "team-skills", "skills": "./extra"}"#,
                  to: plugin.appendingPathComponent(".claude-plugin/plugin.json"))
        try write(#"{"name": "my-market", "plugins": [{"name": "team-skills", "source": "./", "strict": false, "skills": ["./pr-review"]}]}"#,
                  to: market.appendingPathComponent(".claude-plugin/marketplace.json"))
        try write(#"{"my-market": {"installLocation": "\#(market.path)"}}"#,
                  to: home.appendingPathComponent("plugins/known_marketplaces.json"))
        // Installed for this project, with another project's older install
        // listed after it.
        try write("""
            {"version": 2, "plugins": {"team-skills@my-market": [
              {"scope": "local", "projectPath": "\(project.path)", "installPath": "\(plugin.path)"},
              {"scope": "local", "projectPath": "/somewhere/else", "installPath": "\(other.path)"}
            ]}}
            """, to: home.appendingPathComponent("plugins/installed_plugins.json"))
        try write(#"{"enabledPlugins": {"team-skills@my-market": true}}"#,
                  to: project.appendingPathComponent(".claude/settings.local.json"))

        let names = SlashCommandLibrary.find(projectPath: project.path, home: home).map(\.name)
        #expect(names.contains("team-skills:pr-review"))
        #expect(names.contains("team-skills:deploy"))
    }
}
