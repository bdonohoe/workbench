import AppKit
import Darwin
import Observation

/// One running Xcode simulator, as found in the process list.
nonisolated struct Simulator: Identifiable, Equatable, Sendable {
    enum Kind: Sendable {
        case phone, tablet, watch, tv, vision, other

        var symbol: String {
            switch self {
            case .phone: "iphone"
            case .tablet: "ipad"
            case .watch: "applewatch"
            case .tv: "appletv"
            case .vision: "visionpro"
            case .other: "macwindow"
            }
        }

        init(deviceType: String) {
            let type = deviceType.lowercased()
            if type.contains("iphone") || type.contains("ipod") {
                self = .phone
            } else if type.contains("ipad") {
                self = .tablet
            } else if type.contains("watch") {
                self = .watch
            } else if type.contains("apple-tv") {
                self = .tv
            } else if type.contains("vision") {
                self = .vision
            } else {
                self = .other
            }
        }
    }

    /// How much attention a simulator wants, from how long it's been on.
    enum Age: Int, Comparable, Sendable {
        /// Started within the hour.
        case fresh
        /// On for an hour or more.
        case lingering
        /// On for two hours or more, which usually means forgotten.
        case forgotten
        /// On for a day or more.
        case neglected

        init(runningFor seconds: TimeInterval) {
            switch seconds {
            case ..<3600: self = .fresh
            case ..<7200: self = .lingering
            case ..<86400: self = .forgotten
            default: self = .neglected
            }
        }

        static func < (left: Age, right: Age) -> Bool { left.rawValue < right.rawValue }

        /// Read out by VoiceOver, so the color isn't the only way to tell.
        var spoken: String {
            switch self {
            case .fresh: "started recently"
            case .lingering: "on for over an hour"
            case .forgotten: "probably forgotten"
            case .neglected: "on for over a day"
            }
        }
    }

    /// The device's UDID, or a stand-in built from the process ID when the
    /// device's details couldn't be read.
    let id: String
    /// The simulator's own launchd, the parent of everything running in it.
    let pid: pid_t
    let name: String
    /// For example "iOS 27.2". Empty when unknown.
    let runtime: String
    let kind: Kind
    let bootedAt: Date
    /// The folder of devices this one belongs to. Nil when the device's
    /// details couldn't be read, in which case simctl can't address it.
    let deviceSet: URL?

    /// Where the simulator came from, when it isn't one of the regular ones
    /// listed in Xcode. These never show a window, so they're the easiest
    /// to forget about.
    var origin: String? {
        guard let path = deviceSet?.path else { return nil }
        if path.contains("/Previews/") { return "Xcode Previews" }
        if path.contains("/XCTestDevices") { return "Test run" }
        return nil
    }

    func age(at now: Date) -> Age {
        Age(runningFor: now.timeIntervalSince(bootedAt))
    }

    /// "4m", "2h 5m", "3d 4h".
    func runningFor(at now: Date) -> String {
        Self.duration(now.timeIntervalSince(bootedAt))
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds) / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return minutes % 60 == 0 ? "\(hours)h" : "\(hours)h \(minutes % 60)m" }
        return hours % 24 == 0 ? "\(hours / 24)d" : "\(hours / 24)d \(hours % 24)h"
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-27-2" becomes "iOS 27.2".
    /// Some runtimes are built for one device and say so after the version,
    /// as in "iOS-27-2-iPhone19-4". That part is left off.
    static func runtimeName(from identifier: String) -> String {
        guard let last = identifier.split(separator: ".").last else { return "" }
        var parts = last.split(separator: "-").map(String.init)
        guard !parts.isEmpty else { return "" }
        var system = parts.removeFirst()
        if system == "xrOS" { system = "visionOS" }
        let version = parts.prefix { $0.allSatisfy(\.isNumber) }
        return version.isEmpty ? system : system + " " + version.joined(separator: ".")
    }
}

// MARK: - Watching

/// Which simulators are running, for the count at the foot of the sidebar.
///
/// On unless turned off in Settings, and paced like the Mac's meters:
/// - A look at the process list every 10 seconds while Workbench is in
///   front, and every 30 while it's behind other windows, off the main
///   thread. No subprocesses.
/// - Each simulator's memory is added up only while the card is open.
/// - Nothing runs while Workbench's windows are hidden or the count is off.
@Observable
final class SimulatorWatch {
    static let shared = SimulatorWatch()
    static let shownKey = "showsSimulators"

    /// Oldest first.
    private(set) var simulators: [Simulator] = []
    /// Bytes of memory each simulator holds, by simulator ID. Only while
    /// the card is open.
    private(set) var memory: [String: UInt64] = [:]
    /// Simulators that have been told to shut down and haven't gone yet.
    private(set) var shuttingDown: Set<String> = []

    @ObservationIgnored private var watchers = 0
    @ObservationIgnored private var cardOpen = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var scanning = false
    @ObservationIgnored private var scanAgain = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        for name in [NSApplication.didChangeOcclusionStateNotification,
                     NSApplication.didBecomeActiveNotification,
                     NSApplication.didResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reschedule() }
            })
        }
    }

    /// The count came on screen. Scanning runs while at least one is.
    func attach() {
        watchers += 1
        reschedule()
    }

    func detach() {
        watchers = max(0, watchers - 1)
        reschedule()
    }

    func setCardOpen(_ open: Bool) {
        guard open != cardOpen else { return }
        cardOpen = open
        if open { scan() } else { memory = [:] }
        reschedule()
    }

    private func reschedule() {
        guard watchers > 0 else {
            timer?.invalidate()
            timer = nil
            simulators = []
            memory = [:]
            return
        }
        guard NSApp.occlusionState.contains(.visible) else {
            timer?.invalidate()
            timer = nil
            return
        }
        let interval: TimeInterval = cardOpen ? 5 : NSApp.isActive ? 10 : 30
        guard timer?.timeInterval != interval else { return }
        // Coming back on screen, the list may be long out of date.
        if timer == nil { scan() }
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scan() }
        }
        // Slack lets macOS line the wakeup up with others.
        timer.tolerance = interval * 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func scan() {
        guard watchers > 0 else { return }
        guard !scanning else {
            scanAgain = true
            return
        }
        scanning = true
        let known = Dictionary(simulators.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let wantsMemory = cardOpen
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = SimulatorScanner.scan(known: known)
            let held = wantsMemory ? SimulatorScanner.memory(of: Set(found.map(\.pid))) : [:]
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finishScan(found, held: wantsMemory ? held : nil) }
            }
        }
    }

    private func finishScan(_ found: [Simulator], held: [pid_t: UInt64]?) {
        scanning = false
        guard watchers > 0 else { return }
        // Only tell SwiftUI when something it shows has changed.
        if found != simulators {
            simulators = found
            let ids = Set(found.map(\.id))
            shuttingDown.formIntersection(ids)
            memory = memory.filter { ids.contains($0.key) }
        }
        if let held, cardOpen {
            let next = Dictionary(found.compactMap { simulator in
                held[simulator.pid].map { (simulator.id, $0) }
            }, uniquingKeysWith: +)
            // Memory wobbles all the time. A few megabytes isn't news.
            let moved = next.count != memory.count || next.contains { id, bytes in
                abs(Int64(bytes) - Int64(memory[id] ?? 0)) >= 10_000_000
            }
            if moved { memory = next }
        }
        if scanAgain {
            scanAgain = false
            scan()
        }
    }

    /// Shuts the simulator down the way Device > Shut Down does, and stops
    /// it outright if it's still there a few seconds later.
    func shutDown(_ simulator: Simulator) {
        guard !shuttingDown.contains(simulator.id) else { return }
        shuttingDown.insert(simulator.id)
        Task {
            let asked = await SimulatorControl.shutDown(simulator)
            if !asked { SimulatorScanner.stop(simulator, signal: SIGTERM) }
            if await !SimulatorScanner.waitUntilGone(simulator) {
                SimulatorScanner.stop(simulator, signal: SIGKILL)
                _ = await SimulatorScanner.waitUntilGone(simulator)
            }
            shuttingDown.remove(simulator.id)
            scan()
        }
    }

    func shutDownAll() {
        simulators.forEach(shutDown)
    }

    /// The time to measure how long simulators have been on against.
    /// BENCH_SIMULATORS_PRETEND_HOURS=<n> makes them look that much older,
    /// for seeing the colors without waiting a day.
    static func clock(_ date: Date) -> Date {
        #if DEBUG
        if let hours = ProcessInfo.processInfo.environment["BENCH_SIMULATORS_PRETEND_HOURS"].flatMap(Double.init) {
            return date + hours * 3600
        }
        #endif
        return date
    }
}

// MARK: - Finding them

/// Finds running simulators by looking at the process list.
///
/// Every booted simulator has one `launchd_sim` process, started with the
/// path to a file inside the device's folder. Looking for those is far
/// cheaper than asking `simctl`, and it also catches the simulators Xcode
/// boots on its own for previews and test runs.
nonisolated enum SimulatorScanner {
    /// - Parameter known: Simulators from the last scan by process ID, so
    ///   their details aren't read from disk again.
    static func scan(known: [pid_t: Simulator] = [:]) -> [Simulator] {
        var found: [Simulator] = []
        for pid in allProcessIDs() where processName(pid) == "launchd_sim" {
            guard let started = startDate(of: pid) else { continue }
            if let existing = known[pid], existing.bootedAt == started {
                found.append(existing)
            } else {
                found.append(describe(pid: pid, started: started))
            }
        }
        return found.sorted { ($0.bootedAt, $0.id) < ($1.bootedAt, $1.id) }
    }

    /// Whether this simulator's launchd is still running. The start time
    /// is compared too, in case the process ID has been reused.
    static func isRunning(_ simulator: Simulator) -> Bool {
        processName(simulator.pid) == "launchd_sim" && startDate(of: simulator.pid) == simulator.bootedAt
    }

    /// For a simulator that simctl couldn't shut down.
    static func stop(_ simulator: Simulator, signal: Int32) {
        guard isRunning(simulator) else { return }
        kill(simulator.pid, signal)
    }

    static func waitUntilGone(_ simulator: Simulator) async -> Bool {
        for _ in 0..<20 {
            if !isRunning(simulator) { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return !isRunning(simulator)
    }

    private static func describe(pid: pid_t, started: Date) -> Simulator {
        if let path = arguments(of: pid).dropFirst().first(where: { $0.hasPrefix("/") }) {
            // The path is <device set>/<UDID>/data/var/run/launchd_bootstrap.plist.
            // Walk up until the folder holding the device's details.
            var folder = URL(fileURLWithPath: path).deletingLastPathComponent()
            while folder.path != "/" {
                if let details = deviceDetails(in: folder) {
                    let type = details["deviceType"] as? String ?? ""
                    return Simulator(
                        id: details["UDID"] as? String ?? folder.lastPathComponent,
                        pid: pid,
                        name: details["name"] as? String ?? "Simulator",
                        runtime: Simulator.runtimeName(from: details["runtime"] as? String ?? ""),
                        kind: Simulator.Kind(deviceType: type),
                        bootedAt: started,
                        deviceSet: folder.deletingLastPathComponent()
                    )
                }
                folder.deleteLastPathComponent()
            }
        }
        return Simulator(id: "pid-\(pid)", pid: pid, name: "Simulator", runtime: "",
                         kind: .other, bootedAt: started, deviceSet: nil)
    }

    private static func deviceDetails(in folder: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("device.plist")) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    private static func allProcessIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        // Room to spare for processes that start between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return Array(pids.prefix(max(0, Int(filled))))
    }

    private static func processName(_ pid: pid_t) -> String {
        var buffer = [UInt8](repeating: 0, count: 64)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "" }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    private static func startDate(of pid: pid_t) -> Date? {
        guard let info = details(of: pid) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec))
    }

    private static func details(of pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    /// The memory each simulator holds, counting everything running inside
    /// it, by the simulator's process ID. Every process in a simulator
    /// descends from its `launchd_sim`.
    static func memory(of simulators: Set<pid_t>) -> [pid_t: UInt64] {
        guard !simulators.isEmpty else { return [:] }
        var parents: [pid_t: pid_t] = [:]
        for pid in allProcessIDs() {
            if let info = details(of: pid) { parents[pid] = pid_t(info.pbi_ppid) }
        }
        var totals: [pid_t: UInt64] = [:]
        for pid in parents.keys {
            // Walk up the family tree until a simulator, or the top.
            var current = pid
            var steps = 0
            while !simulators.contains(current), let parent = parents[current], parent != current, steps < 32 {
                current = parent
                steps += 1
            }
            if simulators.contains(current) {
                totals[current, default: 0] += footprint(of: pid)
            }
        }
        return totals
    }

    /// The figure Activity Monitor shows in its Memory column.
    private static func footprint(of pid: pid_t) -> UInt64 {
        var usage = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        return result == 0 ? usage.ri_phys_footprint : 0
    }

    /// The arguments a process was started with.
    private static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return [] }

        // The buffer is: argument count, the executable's path, padding
        // zeros, then each argument ending in a zero.
        let count = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = 4
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }

        var arguments: [String] = []
        while arguments.count < Int(count), index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }
}

// MARK: - Shutting them down

/// Talks to simulators through `xcrun simctl`, the tool that ships with Xcode.
nonisolated enum SimulatorControl {
    private static let defaultDeviceSet = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Developer/CoreSimulator/Devices").standardizedFileURL

    /// Asks the simulator to shut down. Returns whether simctl reported success.
    static func shutDown(_ simulator: Simulator) async -> Bool {
        guard let arguments = shutDownArguments(for: simulator) else { return false }
        return await run(arguments) == 0
    }

    /// The simctl command that shuts this simulator down. Ones outside the
    /// regular folder (previews, test runs) need their folder named. Nil
    /// when simctl has no way to address it.
    static func shutDownArguments(for simulator: Simulator) -> [String]? {
        guard let set = simulator.deviceSet else { return nil }
        if set.standardizedFileURL == defaultDeviceSet { return ["simctl", "shutdown", simulator.id] }
        return ["simctl", "--set", set.path, "shutdown", simulator.id]
    }

    private static func run(_ arguments: [String]) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: -1)
            }
        }
    }
}
