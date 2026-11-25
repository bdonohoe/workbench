import AppKit
import Darwin

/// A process's arguments and the Bench tab it came from, read with
/// KERN_PROCARGS2. Works for any process owned by this user.
nonisolated enum ProcessDetails {
    struct Info {
        var arguments: [String]
        /// From `BENCH_TAB_ID`, which every terminal sets and programs inherit.
        var tabID: UUID?
    }

    static func read(_ pid: pid_t) -> Info? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }

        // Layout: argc (Int32), executable path, padding NULs, argv, then env.
        let argc = Int32(bitPattern: UInt32(buffer[0]) | UInt32(buffer[1]) << 8 | UInt32(buffer[2]) << 16 | UInt32(buffer[3]) << 24)
        var i = 4
        while i < size, buffer[i] != 0 { i += 1 }
        while i < size, buffer[i] == 0 { i += 1 }

        var info = Info(arguments: [])
        while i < size, info.arguments.count < argc {
            let start = i
            while i < size, buffer[i] != 0 { i += 1 }
            info.arguments.append(String(decoding: buffer[start..<i], as: UTF8.self))
            i += 1
        }

        let prefix = Array("\(PortScanner.environmentKey)=".utf8)
        while i < size {
            let start = i
            while i < size, buffer[i] != 0 { i += 1 }
            if i == start { break }
            if buffer[start..<i].starts(with: prefix) {
                info.tabID = UUID(uuidString: String(decoding: buffer[(start + prefix.count)..<i], as: UTF8.self))
                break
            }
            i += 1
        }
        return info
    }
}

/// Which Bench tab each process belongs to, worked out from terminal devices.
///
/// macOS hides the environment of its own programs (ssh, /usr/bin/python3,
/// and so on), so `BENCH_TAB_ID` can't always be read. But every tab's login
/// process carries a `bench-tab=<id>` marker (see
/// `RemoteSessionScanner.shellCommand(for:)`), and everything run in a tab
/// shares its terminal device. Built from one `ps` call.
nonisolated struct TerminalSnapshot {
    struct Process {
        var tty: Substring
        var arguments: [String]
    }
    var tabForTTY: [Substring: UUID] = [:]
    var processes: [pid_t: Process] = [:]

    static func capture() -> TerminalSnapshot {
        let process = Foundation.Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axww", "-o", "pid=,tty=,args="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return TerminalSnapshot() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// Parses `ps -o pid=,tty=,args=` output.
    static func parse(_ output: String) -> TerminalSnapshot {
        var snapshot = TerminalSnapshot()
        for line in output.split(separator: "\n") {
            let words = line.split(separator: " ", omittingEmptySubsequences: true)
            guard words.count >= 3, let pid = pid_t(words[0]), words[1] != "??" else { continue }
            let tty = words[1]
            let arguments = words.dropFirst(2).map(String.init)
            snapshot.processes[pid] = Process(tty: tty, arguments: arguments)
            let program = words[2].split(separator: "/").last ?? words[2]
            if program == "login", let range = line.range(of: RemoteSessionScanner.marker),
               let uuid = UUID(uuidString: String(line[range.upperBound...].prefix(36))) {
                snapshot.tabForTTY[tty] = uuid
            }
        }
        return snapshot
    }

    func tab(of pid: pid_t) -> UUID? {
        processes[pid].flatMap { tabForTTY[$0.tty] }
    }
}

/// Finds tabs that are logged in to another machine over ssh, so the
/// sidebar can show their work as happening elsewhere.
///
/// macOS hides the environment of its own programs like /usr/bin/ssh, so the
/// tab ID can't be read from ssh itself. Instead each tab's login process
/// carries a `bench-tab=<id>` marker (see `shellCommand(for:)`), which gives
/// each tab's terminal device. An ssh login on that device belongs to that tab.
final class RemoteSessionScanner {
    private var timer: Timer?
    private var scanning = false
    private let onChange: ([UUID: String]) -> Void
    /// Whether there's any tab to look for. With none, there's no point
    /// listing every process on the Mac every few seconds.
    private let hasTabs: () -> Bool

    nonisolated static let marker = "bench-tab="

    /// The user's login shell with this tab's marker as a trailing comment.
    nonisolated static func shellCommand(for tabID: UUID) -> String {
        "\(loginShell) # \(marker)\(tabID.uuidString)"
    }

    nonisolated private static let loginShell: String = {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }()

    /// Called with each remote tab's host name.
    init(hasTabs: @escaping () -> Bool = { true }, onChange: @escaping ([UUID: String]) -> Void) {
        self.hasTabs = hasTabs
        self.onChange = onChange
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scan() }
        }
        scan()
    }

    private func scan() {
        guard !scanning, hasTabs() else { return }
        scanning = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let hosts = Self.findSessions()
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanning = false
                self.onChange(hosts)
            }
        }
    }

    private nonisolated static func findSessions() -> [UUID: String] {
        sessions(in: TerminalSnapshot.capture())
    }

    /// Tab IDs and their ssh hosts.
    nonisolated static func sessions(in snapshot: TerminalSnapshot) -> [UUID: String] {
        var hosts: [UUID: String] = [:]
        for (pid, process) in snapshot.processes {
            guard let first = process.arguments.first, first.split(separator: "/").last == "ssh",
                  let tab = snapshot.tab(of: pid), let host = interactiveHost(process.arguments) else { continue }
            hosts[tab] = host
        }
        return hosts
    }

    /// The host for an interactive login like `ssh m6-mini` or
    /// `ssh -p 2222 me@box`. Returns nil when ssh runs a command, which is
    /// how git and other tools use it behind the scenes.
    nonisolated static func interactiveHost(_ arguments: [String]) -> String? {
        // ssh options that take a value, per `man ssh`.
        let takesValue = Set("BbcDEeFIiJLlmOoPpQRSWw")
        var index = 1
        var host: String?
        while index < arguments.count {
            let arg = arguments[index]
            index += 1
            if host == nil, arg.hasPrefix("-"), arg.count > 1 {
                if arg.count == 2, let flag = arg.last, takesValue.contains(flag) { index += 1 }
                continue
            }
            if host == nil {
                host = arg
            } else {
                return nil  // Anything after the host is a remote command.
            }
        }
        guard let host else { return nil }
        return host.split(separator: "@").last.map(String.init) ?? host
    }
}
