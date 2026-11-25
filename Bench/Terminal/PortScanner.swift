import AppKit
import Darwin
import Observation

/// A TCP port that a program started from a Bench tab is listening on.
nonisolated struct ListeningPort: Hashable, Identifiable {
    let port: Int
    /// The processes listening on it. Usually one.
    let pids: Set<pid_t>

    var id: Int { port }
    var url: URL { URL(string: "http://localhost:\(port)")! }
}

/// Finds local servers (dev servers, previews, and so on) running in each tab.
///
/// Every terminal starts with `BENCH_TAB_ID` in its environment, and programs
/// inherit it. So Bench lists the listening sockets with lsof and reads each
/// listening process's environment to see which tab it came from. macOS hides
/// the environment of its own programs, so for those Bench falls back to the
/// tab's terminal device (see `TerminalSnapshot`).
///
/// The agents themselves are left out: Claude Code opens a local port of its
/// own in every session, which isn't a server you started, so without this
/// every agent tab showed a port.
@Observable
final class PortScanner {
    private(set) var portsByTab: [UUID: [ListeningPort]] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var scanning = false
    /// Keeps scanning while Bench isn't the active app, when true.
    @ObservationIgnored var scansInBackground: () -> Bool = { false }

    nonisolated static let environmentKey = "BENCH_TAB_ID"

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, NSApp.isActive || self.scansInBackground() else { return }
                self.scan()
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scan() }
        }
        scan()
    }

    func ports(forTab id: UUID) -> [ListeningPort] { portsByTab[id] ?? [] }

    /// All ports across a project's tabs, for the sidebar.
    func ports(for project: Project) -> [ListeningPort] {
        var merged: [Int: Set<pid_t>] = [:]
        for tab in project.tabs {
            for port in portsByTab[tab.id] ?? [] { merged[port.port, default: []].formUnion(port.pids) }
        }
        return merged.map { ListeningPort(port: $0.key, pids: $0.value) }.sorted { $0.port < $1.port }
    }

    /// Asks the processes behind these ports to quit.
    func stop(_ ports: [ListeningPort]) {
        for pid in Set(ports.flatMap(\.pids)) { kill(pid, SIGTERM) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.scan() }
    }

    func scan() {
        guard !scanning else { return }
        scanning = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Self.readPorts()
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanning = false
                if result != self.portsByTab { self.portsByTab = result }
            }
        }
    }

    // MARK: Reading

    nonisolated private static func readPorts() -> [UUID: [ListeningPort]] {
        var byTab: [UUID: [Int: Set<pid_t>]] = [:]
        let sockets = listeningSockets()
        // Built only if some listener's environment can't be read, which is
        // the case for macOS's own programs like /usr/bin/python3.
        var snapshot: TerminalSnapshot?
        for (pid, ports) in sockets {
            let details = ProcessDetails.read(pid)
            if let details, isAgent(details.arguments) { continue }
            var tab = details?.tabID
            if tab == nil {
                if snapshot == nil { snapshot = TerminalSnapshot.capture() }
                if let arguments = snapshot?.processes[pid]?.arguments, isAgent(arguments) { continue }
                tab = snapshot?.tab(of: pid)
            }
            guard let tab else { continue }
            for port in ports { byTab[tab, default: [:]][port, default: []].insert(pid) }
        }
        return byTab.mapValues { ports in
            ports.map { ListeningPort(port: $0.key, pids: $0.value) }.sorted { $0.port < $1.port }
        }
    }

    /// Listening TCP ports for every process this user can see, by pid.
    nonisolated private static func listeningSockets() -> [pid_t: Set<Int>] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pn"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        // -F output is one field per line: "p<pid>" then "n<address>" lines.
        var result: [pid_t: Set<Int>] = [:]
        var pid: pid_t?
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            switch line.first {
            case "p": pid = pid_t(line.dropFirst())
            case "n":
                guard let pid, let colon = line.lastIndex(of: ":"),
                      let port = Int(line[line.index(after: colon)...]) else { continue }
                result[pid, default: []].insert(port)
            default: continue
            }
        }
        return result
    }

    /// The programs the agents run as (see each provider's `program`).
    nonisolated static let agentPrograms: Set<String> = ["claude", "codex"]

    /// Whether these are an agent's own arguments, by the program's name:
    /// "claude", "/opt/homebrew/bin/codex", and so on.
    nonisolated static func isAgent(_ arguments: [String]) -> Bool {
        guard let first = arguments.first, let name = first.split(separator: "/").last else { return false }
        return agentPrograms.contains(String(name))
    }
}
