import Foundation
import Testing

/// Keeps agent-specific code in `Bench/Agents`. The rest of the app works
/// through `AgentProvider` and the interfaces it hands out, so a feature
/// is written once and works for every agent. This reads the app's source
/// and fails when a file outside that folder names one agent's types.
///
/// `known` lists the places that still do, from before the providers
/// existed. It may only get shorter: when one is cleaned up, lower its
/// number here, and never add to it for new code.
struct ProviderLeakTests {
    private static let patterns = [
        "ClaudeProvider", "ClaudeTranscripts", "ClaudeTranscriptFormat", "ClaudeTerminalDriver", "ClaudeBackground",
        "ClaudePlanLimits", "ClaudeSessionStats", "ClaudeEffort", "Agents.claude", ".background(.claude)",
        #"Tools.path("claude")"#,
        "CodexProvider", "CodexTranscripts", "CodexTranscriptFormat", "CodexTerminalDriver", "CodexBackground", "CodexCatalog",
        "Agents.codex", #"Tools.path("codex")"#,
    ]

    /// File, pattern, and how many times it may appear.
    private static let known: [String: Int] = [
        "Model/ClaudeAccount.swift|Tools.path(\"claude\")": 1,
        "Model/ClaudeAccount.swift|.background(.claude)": 1,
        "Model/ClaudeAccounts.swift|Tools.path(\"claude\")": 1,
        "Model/PlanUsageMonitor.swift|.background(.claude)": 1,
        "Views/ClaudeAccountsSettings.swift|Tools.path(\"claude\")": 2,
        "Views/ChatStatusCard.swift|Tools.path(\"claude\")": 1,
        "Views/ClaudeSignInSheet.swift|Tools.path(\"claude\")": 2,
        "Views/SettingsPage.swift|Agents.claude": 1,
    ]

    private static var appFolder: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Bench")
    }

    private static func found() -> [String: Int] {
        var counts: [String: Int] = [:]
        let root = appFolder.standardizedFileURL.path + "/"
        guard let walker = FileManager.default.enumerator(at: appFolder, includingPropertiesForKeys: nil) else { return [:] }
        for case let file as URL in walker where file.pathExtension == "swift" {
            let path = String(file.standardizedFileURL.path.dropFirst(root.count))
            guard !path.hasPrefix("Agents/"), let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            // Comments may name anything.
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            for pattern in patterns {
                let count = code.components(separatedBy: pattern).count - 1
                if count > 0 { counts["\(path)|\(pattern)"] = count }
            }
        }
        return counts
    }

    @Test func theAppsSourceIsThere() {
        #expect(FileManager.default.fileExists(atPath: Self.appFolder.appendingPathComponent("Agents/AgentProvider.swift").path))
    }

    @Test func nothingOutsideTheAgentsFolderNamesOneAgentsTypes() {
        for (place, count) in Self.found().sorted(by: { $0.key < $1.key }) {
            let allowed = Self.known[place] ?? 0
            #expect(count <= allowed, "\(place) appears \(count) times, and \(allowed) are allowed. Go through AgentProvider instead.")
        }
    }

    @Test func theListOfKnownPlacesOnlyShrinks() {
        let found = Self.found()
        for (place, allowed) in Self.known {
            #expect(found[place] ?? 0 == allowed, "\(place) is down to \(found[place] ?? 0). Lower its number in `known`.")
        }
    }
}
