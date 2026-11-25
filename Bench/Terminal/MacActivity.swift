import AppKit
import Darwin
import Observation

/// How hard this Mac is working, for the meter at the foot of the sidebar.
///
/// Built to cost next to nothing:
/// - The meter reads three system counters (CPU ticks, memory, memory
///   pressure) every 10 seconds while Workbench is in front, and every 30
///   while it's behind other windows. No process list, no subprocesses.
/// - The per-project breakdown walks the process list, so it runs only
///   while its hover card is open, every 10 seconds, off the main thread.
/// - Nothing runs while Workbench's windows are hidden or the meter is off.
@Observable
final class MacActivity {
    static let shared = MacActivity()
    static let shownKey = "showsMacActivity"

    enum Pressure: Int, Comparable {
        case normal, warning, critical
        static func < (a: Pressure, b: Pressure) -> Bool { a.rawValue < b.rawValue }
    }

    struct Summary: Equatable {
        /// Percent of the whole Mac, 0 to 100.
        var cpu: Int
        var memoryUsed: UInt64
        var memoryTotal: UInt64
        var pressure: Pressure
        var thermal: ProcessInfo.ThermalState
        var cores: Int

        var memoryPercent: Int { memoryTotal == 0 ? 0 : Int(Double(memoryUsed) / Double(memoryTotal) * 100) }

        /// How it looks overall: what the meter's colors follow.
        var level: Pressure {
            var level = pressure
            if cpu >= 90 || thermal == .serious || thermal == .critical { level = max(level, .critical) }
            else if cpu >= 65 || thermal == .fair { level = max(level, .warning) }
            return level
        }
    }

    /// What one tab, Workbench, or everything else is using.
    struct Share: Equatable {
        /// CPU in cores: 1.0 is one core fully busy.
        var cores: Double = 0
        var memory: UInt64 = 0
    }

    struct Breakdown: Equatable {
        var tabs: [UUID: Share] = [:]
        var workbench = Share()
        var other = Share()
        /// False on the first pass, before there's a second sample to
        /// measure CPU against. Memory is right from the start.
        var hasCPU = false
    }

    private(set) var summary: Summary?
    /// Only while the hover card is open.
    private(set) var breakdown: Breakdown?

    @ObservationIgnored private var meters = 0
    @ObservationIgnored private var cardOpen = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var cardTimer: Timer?
    @ObservationIgnored private var lastTicks: SystemCounters.Ticks?
    @ObservationIgnored private let sampler = ProcessSampler()
    @ObservationIgnored private var sampling = false
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

    /// A meter came on screen. Sampling runs while at least one is.
    func attach() {
        meters += 1
        reschedule()
    }

    func detach() {
        meters = max(0, meters - 1)
        reschedule()
    }

    func setCardOpen(_ open: Bool) {
        guard open != cardOpen else { return }
        cardOpen = open
        if !open { breakdown = nil }
        reschedule()
    }

    private var isVisible: Bool {
        NSApp.occlusionState.contains(.visible)
    }

    /// Starts, stops, or changes the pace of both timers for what's on
    /// screen now.
    private func reschedule() {
        let running = meters > 0 && isVisible
        // Slow enough to read at a glance, and to cost next to nothing.
        let interval: TimeInterval = NSApp.isActive ? 10 : 30
        if running {
            if timer?.timeInterval != interval {
                timer?.invalidate()
                // The first reading only sets the baseline for CPU.
                if summary == nil || lastTicks == nil { tick() }
                timer = makeTimer(interval) { [weak self] in self?.tick() }
            }
        } else {
            timer?.invalidate()
            timer = nil
            // A gap would average CPU over the time away.
            lastTicks = nil
        }

        if running && cardOpen {
            if cardTimer == nil {
                sampleProcesses()
                // CPU needs two samples, so take the second soon after
                // opening, then settle into a calm pace.
                cardTimer = makeTimer(10) { [weak self] in self?.sampleProcesses() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self, self.cardTimer != nil else { return }
                    self.sampleProcesses()
                }
            }
        } else {
            cardTimer?.invalidate()
            cardTimer = nil
            sampler.reset()
        }
    }

    /// A repeating timer with slack, so macOS can line its wakeups up with
    /// others and let the CPU sleep longer.
    private func makeTimer(_ interval: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { action() }
        }
        timer.tolerance = interval * 0.25
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    private func tick() {
        #if DEBUG
        let started = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        defer { Self.dumpTick(summary, took: clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - started) }
        #endif
        let ticks = SystemCounters.cpuTicks()
        var cpu = summary?.cpu ?? 0
        if let ticks, let lastTicks {
            cpu = ticks.percentBusy(since: lastTicks)
        }
        lastTicks = ticks
        let memory = SystemCounters.memoryUsed()
        let next = Summary(cpu: cpu, memoryUsed: memory, memoryTotal: ProcessInfo.processInfo.physicalMemory,
                           pressure: SystemCounters.pressure(), thermal: ProcessInfo.processInfo.thermalState,
                           cores: ProcessInfo.processInfo.activeProcessorCount)
        // Only tell SwiftUI when something it shows has changed.
        if next.cpu != summary?.cpu || next.pressure != summary?.pressure || next.thermal != summary?.thermal
            || abs(next.memoryPercent - (summary?.memoryPercent ?? -1)) >= 1 {
            summary = next
        }
    }

    private func sampleProcesses() {
        guard !sampling else { return }
        sampling = true
        let sampler = sampler
        DispatchQueue.global(qos: .utility).async { [weak self] in
            #if DEBUG
            let started = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            #endif
            let result = sampler.sample()
            #if DEBUG
            Self.dump(result, took: clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - started)
            #endif
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.sampling = false
                    if self.cardOpen, result != self.breakdown { self.breakdown = result }
                }
            }
        }
    }
}

#if DEBUG
extension MacActivity {
    /// BENCH_ACTIVITY_DUMP=<file> appends each reading and how long it
    /// took, for checking the numbers and what measuring costs.
    nonisolated static func dump(_ breakdown: Breakdown, took: UInt64) {
        var lines = ["sample took \(Double(took) / 1_000_000) ms, hasCPU \(breakdown.hasCPU)"]
        for (tab, share) in breakdown.tabs.sorted(by: { $0.value.cores > $1.value.cores }) {
            lines.append("  tab \(tab.uuidString.prefix(8)) \(String(format: "%.2f", share.cores)) cores \(share.memory / 1_048_576) MB")
        }
        lines.append("  workbench \(String(format: "%.2f", breakdown.workbench.cores)) cores \(breakdown.workbench.memory / 1_048_576) MB")
        lines.append("  other \(String(format: "%.2f", breakdown.other.cores)) cores \(breakdown.other.memory / 1_048_576) MB")
        append(lines.joined(separator: "\n"))
    }

    static func dumpTick(_ summary: Summary?, took: UInt64) {
        guard let summary else { return }
        append("tick took \(Double(took) / 1_000_000) ms: cpu \(summary.cpu)% mem \(summary.memoryPercent)% pressure \(summary.pressure) thermal \(summary.thermal.rawValue)")
    }

    nonisolated private static func append(_ text: String) {
        guard let path = ProcessInfo.processInfo.environment["BENCH_ACTIVITY_DUMP"] else { return }
        let line = Data((text + "\n").utf8)
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: line)
        }
    }
}
#endif

// MARK: - Whole-Mac counters

/// The handful of numbers the meter needs, each one cheap system call.
nonisolated enum SystemCounters {
    private static let host = mach_host_self()

    struct Ticks {
        var busy: UInt64
        var total: UInt64

        func percentBusy(since earlier: Ticks) -> Int {
            let total = self.total &- earlier.total
            guard total > 0 else { return 0 }
            return Int((Double(busy &- earlier.busy) / Double(total) * 100).rounded())
        }
    }

    /// All cores' CPU time so far, in scheduler ticks.
    static func cpuTicks() -> Ticks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        return Ticks(busy: user + system + nice, total: user + system + idle + nice)
    }

    /// Memory in use the way Activity Monitor counts it: app memory, wired,
    /// and compressed.
    static func memoryUsed() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        var pageSize: vm_size_t = 0
        host_page_size(host, &pageSize)
        let app = UInt64(stats.internal_page_count) &- UInt64(stats.purgeable_count)
        let pages = app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        return pages * UInt64(pageSize)
    }

    /// The system's own judgment of memory: the same signal that makes
    /// macOS start compressing and swapping hard.
    static func pressure() -> MacActivity.Pressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
        switch level {
        case 4...: return .critical
        case 2...: return .warning
        default: return .normal
        }
    }
}

// MARK: - Per-process breakdown

/// Adds up CPU and memory for every process this user owns, by the
/// Workbench tab it came from. Used only while the hover card is open.
///
/// A tab's programs share its terminal device, so once one process on a
/// device shows its tab (from `BENCH_TAB_ID`), the rest follow without
/// reading their environments. Each process's environment is read at most
/// once in its life.
///
/// Builds start and finish many short compiler processes between samples.
/// Their CPU time shows up in their parent's "children" total when they
/// exit, so it's counted there instead of being lost.
nonisolated final class ProcessSampler: @unchecked Sendable {
    private struct Key: Hashable {
        var pid: pid_t
        var started: UInt64
    }

    private struct Seen {
        var parent: pid_t
        /// Own CPU time plus that of children it has collected, in ns.
        var cpu: UInt64
        var tab: UUID?
    }

    private let lock = NSLock()
    private var seen: [Key: Seen] = [:]
    /// Processes whose environment has been read already.
    private var envChecked: Set<Key> = []
    private var lastSample: UInt64 = 0

    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(max(info.denom, 1)))
    }()

    func reset() {
        lock.lock()
        seen = [:]
        envChecked = []
        lastSample = 0
        lock.unlock()
    }

    func sample() -> MacActivity.Breakdown {
        lock.lock()
        defer { lock.unlock() }

        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let elapsed = lastSample == 0 ? 0 : now &- lastSample
        let me = getpid()
        let uid = getuid()

        struct Current {
            var key: Key
            var parent: pid_t
            var tty: UInt32
            var cpu: UInt64
            var memory: UInt64
        }
        var current: [Current] = []
        for pid in Self.allPIDs() where pid > 0 {
            var bsd = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size, bsd.pbi_uid == uid else { continue }
            var usage = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard ok == 0 else { continue }
            let ticks = usage.ri_user_time + usage.ri_system_time + usage.ri_child_user_time + usage.ri_child_system_time
            let key = Key(pid: pid, started: UInt64(bsd.pbi_start_tvsec) * 1_000_000 + UInt64(bsd.pbi_start_tvusec))
            current.append(Current(key: key, parent: pid_t(bsd.pbi_ppid), tty: bsd.e_tdev,
                                   cpu: ticks * Self.timebase.numer / Self.timebase.denom,
                                   memory: usage.ri_phys_footprint))
        }

        // Which tab each terminal device belongs to, from processes already
        // known, then from reading environments where needed.
        let noTTY = UInt32.max
        var tabForTTY: [UInt32: UUID] = [:]
        for process in current where process.tty != noTTY {
            if let tab = seen[process.key]?.tab { tabForTTY[process.tty] = tab }
        }
        var tabs: [Key: UUID] = [:]
        var unresolved: [Current] = []
        for process in current {
            let known: UUID? = seen[process.key].flatMap(\.tab)
            let byDevice: UUID? = process.tty != noTTY ? tabForTTY[process.tty] : nil
            if let tab = known ?? byDevice {
                tabs[process.key] = tab
            } else if !envChecked.contains(process.key) {
                // Read each process's environment once in its life.
                envChecked.insert(process.key)
                if let tab = ProcessDetails.read(process.key.pid)?.tabID {
                    tabs[process.key] = tab
                    if process.tty != noTTY { tabForTTY[process.tty] = tab }
                }
            } else {
                unresolved.append(process)
            }
        }
        // Devices learned late in the pass cover processes seen earlier.
        for process in unresolved where process.tty != noTTY {
            if let tab = tabForTTY[process.tty] { tabs[process.key] = tab }
        }

        // When a process exits, its parent's children total takes in CPU
        // time already counted while it ran. Take that back out.
        let alive = Set(current.map(\.key))
        var counted: [pid_t: UInt64] = [:]
        for (key, old) in seen where !alive.contains(key) {
            counted[old.parent, default: 0] += old.cpu
        }
        envChecked.formIntersection(alive)

        var result = MacActivity.Breakdown()
        result.hasCPU = elapsed > 0
        var next: [Key: Seen] = [:]
        for process in current {
            let tab = tabs[process.key]
            var delta: UInt64 = 0
            if elapsed > 0 {
                if let old = seen[process.key] {
                    let before = old.cpu + (counted[process.key.pid] ?? 0)
                    delta = process.cpu > before ? process.cpu - before : 0
                } else {
                    // New since the last sample: all its time is new.
                    delta = process.cpu
                }
            }
            let cores = elapsed > 0 ? Double(delta) / Double(elapsed) : 0
            let add = { (share: inout MacActivity.Share) in
                share.cores += cores
                share.memory += process.memory
            }
            if process.key.pid == me {
                add(&result.workbench)
            } else if let tab {
                add(&result.tabs[tab, default: MacActivity.Share()])
            } else {
                add(&result.other)
            }
            next[process.key] = Seen(parent: process.parent, cpu: process.cpu, tab: tab)
        }
        seen = next
        lastSample = now
        return result
    }

    private static func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        return Array(pids.prefix(Int(count)))
    }
}
