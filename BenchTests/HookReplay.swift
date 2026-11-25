import BenchKit
import Foundation
import Testing
@testable import Bench

/// Puts recorded hook payloads through an agent's hook commands, one at a
/// time, and writes down what the tab's state says and what the watcher
/// reads back after each. `fire` runs one payload's hooks.
@MainActor
enum HookReplay {
    private static func describe(_ details: AgentDetails?) -> [String] {
        guard let details else { return ["  (nothing)"] }
        var lines: [String] = []
        func add(_ name: String, _ value: String?) { if let value { lines.append("  \(name): \(value.replacingOccurrences(of: "\n", with: "⏎"))") } }
        add("state", details.state?.rawValue)
        add("prompt", details.prompt)
        add("tool", details.toolName)
        add("action", details.action)
        add("plain action", details.plainAction)
        add("command", details.command)
        add("question", details.question)
        add("question kind", details.questionKind)
        add("allow or deny", details.isAllowOrDeny ? "yes" : nil)
        add("picker", details.questions.map { questions in
            questions.map { "\($0.question) [\($0.options.map(\.label).joined(separator: ", "))]" }.joined(separator: "; ")
        })
        add("summary", details.summary)
        add("start model", details.startModel)
        add("switched model", details.switchedModel)
        add("compacting", details.isCompacting ? "yes" : nil)
        add("transcript", details.transcriptPath)
        return lines
    }

    static func run(_ payloads: [[String: Any]], named session: String,
                    fire: ([String: Any], [String: String]) throws -> Void) throws -> String {
        let tab = UUID()
        let stateFile = AgentSessions.stateFolder.appendingPathComponent(tab.uuidString)
        let sessionFile = FileManager.default.temporaryDirectory.appendingPathComponent("bench-session-\(tab.uuidString).json")
        try FileManager.default.createDirectory(at: AgentSessions.stateFolder, withIntermediateDirectories: true)
        defer {
            AgentSessions.prune(keeping: Set(AgentSessions.openSessions().values).subtracting([tab]))
            let left = (try? FileManager.default.contentsOfDirectory(at: AgentSessions.stateFolder, includingPropertiesForKeys: nil)) ?? []
            for file in left where file.lastPathComponent.hasPrefix(tab.uuidString) { try? FileManager.default.removeItem(at: file) }
            try? FileManager.default.removeItem(at: sessionFile)
        }
        let environment = ["BENCH_STATE_FILE": stateFile.path, "BENCH_SESSION_FILE": sessionFile.path,
                           "BENCH_COMMANDS": BenchCommand.version, "PATH": "/usr/bin:/bin"]

        var text = ""
        var last: [String] = []
        for var payload in payloads {
            // A transcript that isn't on this Mac: the watcher would read
            // the real one for a summary, and it's only on the Mac that
            // recorded it.
            payload["transcript_path"] = "/recorded/\(session).jsonl"
            try fire(payload, environment)
            var read: AgentDetails?
            _ = AgentStateWatcher { read = $0[tab] }
            let event = payload["hook_event_name"] as? String ?? "?"
            let detail = (payload["tool_name"] ?? payload["notification_type"] ?? payload["source"] ?? payload["reason"]) as? String
            text += "\(event)\(detail.map { " (\($0))" } ?? "")"
                + "  session file: \(FileManager.default.fileExists(atPath: sessionFile.path) ? "yes" : "no")\n"
            let now = describe(read)
            if now != last { text += now.joined(separator: "\n") + "\n" }
            last = now
        }
        return text
    }
}

extension HookReplay {
    /// Runs one shell command the way an agent runs a hook: the event's
    /// JSON on its input.
    static func shell(_ command: String, input: Data, environment: [String: String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = environment
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        stdin.fileHandleForWriting.write(input)
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
    }
}
