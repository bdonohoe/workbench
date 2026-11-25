import CryptoKit
import Darwin
import Foundation

/// Keeps Claude tabs running while Workbench quits and opens again, as for
/// an update.
///
/// A kept tab's terminal runs `bench-session attach` instead of the shell.
/// That relay joins the tab's session in the keeper (`bench-session serve`),
/// a separate process that holds the shell and Claude. Quitting ends the
/// relay, not the session, and after the relaunch the tab joins it again.
///
/// If the keeper goes away (it crashed, or someone killed it), each kept
/// tab starts again with Claude resuming its conversation, rather than
/// closing.
///
/// Off unless turned on as Keep Working in Settings › General, which sets
/// `keepsClaudeSessionsAlive`.
enum SessionKeeper {
    static let enabledKey = "keepsClaudeSessionsAlive"
    /// What the relay types into a new session (see Relay.swift).
    static let inputVariable = "BENCH_SESSION_INPUT"

    /// Whether new Claude tabs go through the keeper. Settled by
    /// `prepare()` at launch, and turned off if the keeper can't be started.
    private(set) static var isActive = false

    /// The running keeper, as it names itself. A tab notes the one it
    /// started with, to tell later whether that keeper went away.
    private(set) static var instance: String?

    /// Tabs whose sessions were already running when Workbench opened.
    private static var runningAtLaunch: Set<UUID> = []

    /// Set by Quit Workbench Completely: this quit ends kept tabs too, as
    /// if Keep Working were off. Cleared again if the quit is cancelled.
    static var endsSessionsAtQuit = false

    /// Whether Keep Working is turned on. New Claude tabs go through the
    /// keeper only while it is.
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// Turns Keep Working on or off from Settings. On applies to Claude
    /// tabs opened from now on, and to every tab after the next launch.
    /// Off: new tabs run the usual way, and tabs already kept stop at the
    /// next quit like any other (see `endForQuit()`). False if it was
    /// turned on but the keeper couldn't be started.
    @discardableResult
    static func setEnabled(_ on: Bool) -> Bool {
        UserDefaults.standard.set(on, forKey: enabledKey)
        guard on else { return true }
        if !isActive { prepare(atLaunch: false) }
        return isActive
    }

    /// Starts the keeper, or finds the one still running from before.
    /// Call once at launch, before any tab starts, and again if Keep
    /// Working is turned on later.
    static func prepare(atLaunch: Bool = true) {
        guard isEnabled else {
            // Turned off since the last quit: end what an earlier keeper
            // still holds, so Claude isn't left running unseen beside the
            // copy each tab resumes.
            if atLaunch { endSessions(at: socketPath) }
            return
        }
        guard let copied = copyHelper() else {
            NSLog("Workbench: couldn't find bench-session, so tabs won't be kept")
            return
        }
        helper = copied
        endOlderKeepers()
        retireKeeperFromEndedLogin()
        if let tabs = start() {
            if atLaunch {
                runningAtLaunch = tabs
            } else {
                // No tab open now was kept, so nothing should join these.
                for tab in tabs { end(tab, now: true) }
            }
            isActive = true
        }
    }

    /// As Workbench quits with Keep Working turned off, ends the sessions
    /// of tabs that were kept before it was, as quitting would have. Ends
    /// them all for Quit Workbench Completely.
    static func endForQuit() {
        guard isActive, !isEnabled || endsSessionsAtQuit else { return }
        endSessions(at: socketPath, noting: false)
    }

    /// True if the tab's session was running when Workbench opened.
    static func wasRunningAtLaunch(_ tabID: UUID) -> Bool {
        isActive && runningAtLaunch.contains(tabID)
    }

    /// True the first time it's asked about a tab that was running at
    /// launch: that tab joins its session instead of starting Claude.
    static func takeRunning(_ tabID: UUID) -> Bool {
        runningAtLaunch.remove(tabID) != nil
    }

    /// Ends sessions left running for tabs that no longer exist, like one
    /// closed just as Workbench crashed.
    static func endLeftovers(keeping tabIDs: Set<UUID>) {
        for tabID in runningAtLaunch where !tabIDs.contains(tabID) {
            runningAtLaunch.remove(tabID)
            end(tabID)
        }
    }

    /// The keeper running now, starting a new one if the last went away.
    /// Nil if none could be started: then tabs run the usual way.
    static func currentInstance() -> String? {
        guard isActive else { return nil }
        if let reply = KeeperWire.ask(socketPath, .init(op: .list), timeout: 1), reply.ok, let keeper = reply.keeper {
            instance = keeper
            return keeper
        }
        // Gone: it crashed, was killed, or ended itself with nothing to keep.
        guard start() != nil else {
            // Tabs started from here on run the usual way.
            isActive = false
            instance = nil
            return nil
        }
        return instance
    }

    /// In the per-user temporary folder, which unlike Application Support
    /// keeps the path short enough for a socket. Named after this copy's
    /// support folder, so a test copy gets its own keeper, and after the
    /// wire version, so a Workbench that speaks a newer one never joins an
    /// older keeper.
    static let socketPath: String = {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        let folder = length > 0 ? String(cString: buffer) : NSTemporaryDirectory()
        let digest = SHA256.hash(data: Data(BenchPaths.support.path.utf8))
        let name = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        return (folder as NSString).appendingPathComponent("bench-keeper-\(name)-v\(KeeperWire.version).sock")
    }()

    /// The helper, copied out of the app. Sparkle swaps the whole app when
    /// it updates, and the keeper has to keep running from a file that
    /// stays put.
    private static var helper: String?

    /// The shell command for a kept tab's terminal: the relay, carrying the
    /// shell it would otherwise have run.
    static func relayCommand(tabID: UUID, shell: String) -> String {
        guard let helper else { return shell }
        let marker = "\(RemoteSessionScanner.marker)\(tabID.uuidString)"
        return "\(quote(helper)) attach --socket \(quote(socketPath)) --tab \(tabID.uuidString) -- \(quote(shell)) # \(marker)"
    }

    /// The tabs with a session in the keeper right now, or nil if it
    /// didn't answer.
    static func liveTabs() -> Set<UUID>? {
        guard isActive else { return nil }
        return list()
    }

    /// Ends a tab's session, as closing the tab should. `now` waits for the
    /// keeper's answer, for when Workbench is about to quit.
    static func end(_ tabID: UUID, now: Bool = false) {
        guard isActive || now else { return }
        let path = socketPath
        let tab = tabID.uuidString
        if now {
            _ = KeeperWire.ask(path, .init(op: .kill, tab: tab), timeout: 1)
            return
        }
        Task.detached(priority: .userInitiated) {
            _ = KeeperWire.ask(path, .init(op: .kill, tab: tab), timeout: 2)
        }
    }

    // MARK: Starting the keeper

    /// Finds or starts the keeper and returns its tabs, or nil if there's
    /// no keeper to be had.
    private static func start() -> Set<UUID>? {
        if let tabs = list() { return tabs }
        guard let helper, spawnKeeper(helper) else { return nil }
        for _ in 0..<40 {
            usleep(50_000)
            if let tabs = list() { return tabs }
        }
        NSLog("Workbench: the session keeper didn't start")
        return nil
    }

    private static func list() -> Set<UUID>? {
        guard let reply = KeeperWire.ask(socketPath, .init(op: .list), timeout: 1), reply.ok else { return nil }
        instance = reply.keeper
        return Set((reply.tabs ?? []).compactMap(UUID.init(uuidString:)))
    }

    /// Ends the sessions of keepers left by a Workbench that attached
    /// differently, which this one can't join, so Claude isn't left
    /// running unseen beside the copy this tab starts. Busy ones are noted
    /// for Restart Recovery, as a quit would have.
    private static func endOlderKeepers() {
        let folder = (socketPath as NSString).deletingLastPathComponent
        let mine = (socketPath as NSString).lastPathComponent
        let prefix = mine.prefix(upTo: mine.range(of: "-v")!.lowerBound) + "-v"
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        where name.hasPrefix(prefix) && name.hasSuffix(".sock") && name != mine {
            endSessions(at: (folder as NSString).appendingPathComponent(name))
        }
    }

    /// True if a keeper reporting `theirs` started in a login session other
    /// than `mine`. Unknown on either side counts as the same, since keepers
    /// from before the field can't say.
    static func outlivedLogin(theirs: Int32?, mine: Int32?) -> Bool {
        guard let theirs, let mine else { return false }
        return theirs != mine
    }

    /// A keeper still running from before you logged out and back in can't
    /// start new shells: `login` there can't look up your account, so a new
    /// tab shows "Login incorrect" and a `login:` prompt. Ends its sessions,
    /// noting busy ones for Restart Recovery, and has it quit so a fresh
    /// keeper starts in this login session. Each tab then resumes its
    /// conversation.
    private static func retireKeeperFromEndedLogin() {
        guard let reply = KeeperWire.ask(socketPath, .init(op: .list), timeout: 1), reply.ok,
              outlivedLogin(theirs: reply.loginSession, mine: KeeperWire.loginSession()) else { return }
        NSLog("Workbench: the session keeper is from an earlier login, so starting a new one")
        endSessions(at: socketPath)
        _ = KeeperWire.ask(socketPath, .init(op: .quit), timeout: 1)
        // A new keeper can't start until the old one lets go of its lock.
        let lock = open(socketPath + ".lock", O_RDWR | O_CLOEXEC)
        guard lock >= 0 else { return }
        defer { close(lock) }
        for _ in 0..<40 {
            if flock(lock, LOCK_EX | LOCK_NB) == 0 {
                flock(lock, LOCK_UN)
                return
            }
            usleep(50_000)
        }
        NSLog("Workbench: the old session keeper didn't quit")
    }

    /// Ends every session a keeper holds, noting each for Restart Recovery
    /// unless the quit already has.
    private static func endSessions(at path: String, noting: Bool = true) {
        guard let reply = KeeperWire.ask(path, .init(op: .list), timeout: 1), reply.ok else { return }
        for tab in reply.tabs ?? [] {
            if noting, let tabID = UUID(uuidString: tab) { RestartRecovery.shared.noteStopped(tabID) }
            _ = KeeperWire.ask(path, .init(op: .kill, tab: tab), timeout: 1)
        }
    }

    /// Copies the helper into Application Support under a name taken from
    /// its contents, claims it, and clears out copies no other Workbench
    /// has claimed. A keeper still running from one of those carries on:
    /// macOS keeps a deleted file around for a process using it. But a
    /// Workbench still running beside this one (a Debug build next to the
    /// installed app, say) execs its copy for every tab it opens, so its
    /// copy stays.
    private static func copyHelper() -> String? {
        let source = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/bench-session")
        guard let data = try? Data(contentsOf: source) else { return nil }
        let name = "bench-session-" + SHA256.hash(data: data).prefix(6).map { String(format: "%02x", $0) }.joined()
        let folder = BenchPaths.support.appendingPathComponent("session-keeper", isDirectory: true)
        let target = folder.appendingPathComponent(name)
        let files = FileManager.default
        if !files.isExecutableFile(atPath: target.path) {
            do {
                try files.createDirectory(at: folder, withIntermediateDirectories: true)
                let temporary = folder.appendingPathComponent(name + ".partial")
                try? files.removeItem(at: temporary)
                try files.copyItem(at: source, to: temporary)
                try files.moveItem(at: temporary, to: target)
            } catch {
                NSLog("Workbench: couldn't copy bench-session: \(error)")
                return nil
            }
        }
        if helperClaim < 0 { helperClaim = claim(target.path) }
        removeUnclaimedHelpers(in: folder, keeping: name)
        return target.path
    }

    /// The descriptor holding this Workbench's claim on its helper copy,
    /// open for as long as it runs.
    private static var helperClaim: Int32 = -1

    /// Marks a helper copy as in use by this process, with a shared lock
    /// held as long as the returned descriptor stays open. Every Workbench
    /// using the copy holds one; nothing is inherited by what Workbench
    /// starts. -1 if the file couldn't be opened.
    static func claim(_ path: String) -> Int32 {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return -1 }
        guard flock(descriptor, LOCK_SH) == 0 else {
            close(descriptor)
            return -1
        }
        return descriptor
    }

    /// Removes every helper copy in the folder but `name` that no running
    /// Workbench has claimed: one still claimed won't take an exclusive
    /// lock.
    static func removeUnclaimedHelpers(in folder: URL, keeping name: String) {
        let files = FileManager.default
        for old in (try? files.contentsOfDirectory(atPath: folder.path)) ?? []
        where old.hasPrefix("bench-session-") && old != name {
            let path = folder.appendingPathComponent(old).path
            let descriptor = open(path, O_RDONLY | O_CLOEXEC)
            guard descriptor >= 0 else { continue }
            defer { close(descriptor) }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { continue }
            try? files.removeItem(atPath: path)
        }
    }

    /// Starts the keeper in a session of its own, holding none of
    /// Workbench's open files. Otherwise it would keep Workbench's
    /// terminals open after a quit and its relays would never hang up.
    private static func spawnKeeper(_ path: String) -> Bool {
        let log = BenchPaths.support.appendingPathComponent("session-keeper/keeper.log").path
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, log, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)

        let environment = ProcessInfo.processInfo.environment
        let env = ["HOME", "USER", "LOGNAME", "TMPDIR"].compactMap { key in environment[key].map { "\(key)=\($0)" } }
            + ["PATH=/usr/bin:/bin:/usr/sbin:/sbin"]
        let argv = [path, "serve", "--socket", socketPath]
        var cArgv = argv.map { strdup($0) } + [nil]
        var cEnv = env.map { strdup($0) } + [nil]
        defer { (cArgv + cEnv).forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, path, &actions, &attributes, &cArgv, &cEnv)
        guard result == 0 else {
            NSLog("Workbench: couldn't start the session keeper: \(String(cString: strerror(result)))")
            return false
        }
        // Collects it if it exits while Workbench is still open, so it
        // doesn't linger as a zombie.
        // On the main queue: this file's code belongs to the main actor,
        // and running it anywhere else stops the app.
        let reaper = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        reaper.setEventHandler {
            var status: Int32 = 0
            waitpid(pid, &status, WNOHANG)
            reaper.cancel()
        }
        reaper.resume()
        return true
    }

    private static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
