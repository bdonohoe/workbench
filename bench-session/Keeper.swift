import Darwin
import Foundation

/// `bench-session serve`: owns the terminal of every kept tab, so the
/// shell and whatever runs in it (Claude) outlive Workbench quitting.
///
/// Each session is a pseudo-terminal with `login` on the far end, started
/// just as Ghostty starts a tab's shell. A tab's relay attaches to it and
/// passes bytes through. While nothing is attached the keeper keeps reading
/// the output, so the program never blocks, and drops it: Claude redraws
/// its screen when the next relay attaches.
///
/// Everything runs on one serial queue. Descriptors are non-blocking, and
/// writes wait in an `Outbox` until the other side takes them.
final class Keeper {
    private let queue = DispatchQueue(label: "bench-session.keeper")
    private let socketPath: String
    private var sessions: [String: Session] = [:]
    private var clients: [ObjectIdentifier: Client] = [:]
    private var listenSource: DispatchSourceRead?
    private var idleTimer: DispatchSourceTimer?
    /// When anything last connected. The keeper only ends itself after a
    /// quiet spell, so it can't vanish between Workbench checking on it and
    /// a new tab's relay arriving.
    private var lastConnection = Date()

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        signal(SIGHUP, SIG_IGN)
        // Only one keeper per socket. The lock is held until this exits.
        let lock = open(socketPath + ".lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            log("another keeper is running")
            exit(0)
        }
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var address = KeeperWire.unixAddress(socketPath)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(socketPath, 0o600) == 0, listen(fd, 16) == 0 else {
            log("couldn't listen at \(socketPath): \(String(cString: strerror(errno)))")
            exit(1)
        }
        setNonBlocking(fd)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [unowned self] in accept(on: fd) }
        source.resume()
        listenSource = source

        // Goes away once it has nothing left to keep.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [unowned self] in
            if sessions.isEmpty, clients.isEmpty, Date().timeIntervalSince(lastConnection) > 20 {
                log("nothing left to keep, exiting")
                unlink(socketPath)
                exit(0)
            }
        }
        timer.resume()
        idleTimer = timer
        log("listening at \(socketPath)")
        dispatchMain()
    }

    // MARK: Connections

    private func accept(on listener: Int32) {
        while true {
            let fd = Darwin.accept(listener, nil, nil)
            guard fd >= 0 else { return }
            lastConnection = Date()
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            setNonBlocking(fd)
            let client = Client(fd: fd, queue: queue)
            clients[ObjectIdentifier(client)] = client
            client.onBytes = { [unowned self, unowned client] in received(from: client) }
            client.onClose = { [unowned self, unowned client] in dropped(client) }
            client.start()
        }
    }

    private func dropped(_ client: Client) {
        clients[ObjectIdentifier(client)] = nil
        if let tab = client.tab, let session = sessions[tab], session.client === client {
            session.client = nil
        }
    }

    private func received(from client: Client) {
        if client.request == nil {
            guard let newline = client.inbox.firstIndex(of: UInt8(ascii: "\n")) else {
                if client.inbox.count > 1 << 20 { client.close() }
                return
            }
            let line = client.inbox[client.inbox.startIndex..<newline]
            client.inbox.removeSubrange(client.inbox.startIndex...newline)
            guard let request = try? JSONDecoder().decode(KeeperWire.Request.self, from: Data(line)) else {
                client.reply(.init(ok: false, error: "bad request"), thenClose: true)
                return
            }
            client.request = request
            // Listing and ending sessions work for any version.
            guard request.v == KeeperWire.version || request.op != .attach else {
                client.reply(.init(ok: false, error: "version \(KeeperWire.version) keeper"), thenClose: true)
                return
            }
            handle(request, from: client)
        }
        guard let tab = client.tab, let session = sessions[tab], session.client === client else { return }
        for (type, payload) in KeeperWire.takeFrames(&client.inbox) {
            switch type {
            case .data: session.master.send(payload)
            case .resize where payload.count >= 4:
                session.resize(cols: KeeperWire.uint16(payload, at: 0), rows: KeeperWire.uint16(payload, at: 2))
            default: break
            }
        }
    }

    private func handle(_ request: KeeperWire.Request, from client: Client) {
        switch request.op {
        case .list:
            client.reply(.init(ok: true, tabs: sessions.keys.sorted()), thenClose: true)
        case .quit:
            // Workbench found this keeper outlived the login session it
            // started in, so new shells here can't log in.
            log("asked to quit, ending \(sessions.count) session(s)")
            for session in sessions.values { session.hangUp() }
            client.reply(.init(ok: true), thenClose: true)
            listenSource?.cancel()
            unlink(socketPath)
            // A moment for the reply to go out. Exiting frees the lock, so a
            // new keeper can start at this socket.
            queue.asyncAfter(deadline: .now() + 0.1) { exit(0) }
        case .kill:
            if let tab = request.tab, let session = sessions[tab] {
                log("ending \(tab)")
                session.hangUp()
            }
            client.reply(.init(ok: true), thenClose: true)
        case .attach:
            guard let tab = request.tab else {
                client.reply(.init(ok: false, error: "no tab"), thenClose: true)
                return
            }
            client.tab = tab
            let cols = request.cols ?? 80, rows = request.rows ?? 24
            if let session = sessions[tab] {
                // A newer relay wins: the old one belongs to a window that's gone.
                if let old = session.client, old !== client { old.close() }
                session.client = client
                client.reply(.init(ok: true, created: false), thenClose: false)
                log("reattached \(tab)")
                session.redraw(cols: cols, rows: rows)
            } else {
                guard let session = Session.start(tab: tab, request: request, cols: cols, rows: rows, queue: queue) else {
                    client.reply(.init(ok: false, error: "couldn't start the shell"), thenClose: true)
                    return
                }
                sessions[tab] = session
                session.client = client
                session.onExit = { [unowned self, weak session] status in
                    log("\(tab) exited with \(status)")
                    let client = session?.client
                    if let session, sessions[tab] === session { sessions[tab] = nil }
                    client?.send(KeeperWire.frame(.exit, withUnsafeBytes(of: status.bigEndian) { Data($0) }))
                    client?.closeWhenSent()
                }
                client.reply(.init(ok: true, created: true), thenClose: false)
                log("started \(tab), pid \(session.pid)")
                if let input = request.input, !input.isEmpty { session.master.send(Data(input.utf8)) }
            }
        }
    }
}

/// Tells this keeper apart from any that ran before it.
let keeperInstance = UUID().uuidString

/// The login session this keeper started in, reported with every reply.
let keeperLoginSession = KeeperWire.loginSession()

// MARK: - Session

final class Session {
    let tab: String
    let pid: pid_t
    let master: Outbox
    private let fd: Int32
    private let queue: DispatchQueue
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private var hungUp = false
    weak var client: Client?
    /// The terminal settings the program has made, for the next relay.
    private var memory = TerminalMemory()
    var onExit: ((Int32) -> Void)?

    private init(tab: String, pid: pid_t, fd: Int32, queue: DispatchQueue) {
        self.tab = tab
        self.pid = pid
        self.fd = fd
        self.queue = queue
        master = Outbox(fd: fd, queue: queue)
    }

    static func start(tab: String, request: KeeperWire.Request, cols: UInt16, rows: UInt16, queue: DispatchQueue) -> Session? {
        var env = request.env ?? [:]
        let command = request.command ?? Shell.userShell
        Shell.addIntegration(for: command, to: &env)
        let argv = Shell.loginArguments(command: command)
        let home = env["HOME"] ?? NSHomeDirectory()
        let cwd = request.cwd ?? home

        // Everything the child needs is made before forking: after fork it
        // may only make plain system calls.
        let cArgv = CStrings(argv)
        let cEnv = CStrings(env.map { "\($0.key)=\($0.value)" })
        let cCwd = strdup(cwd)!, cHome = strdup(home)!
        defer { free(cCwd); free(cHome) }

        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        var master: Int32 = -1
        let pid = forkpty(&master, nil, nil, &size)
        if pid == 0 {
            // The child: put back what the keeper changed, then become login.
            for sig in 1..<NSIG { signal(sig, SIG_DFL) }
            var none = sigset_t()
            sigemptyset(&none)
            sigprocmask(SIG_SETMASK, &none, nil)
            if chdir(cCwd) != 0 { _ = chdir(cHome) }
            execve(cArgv.pointer[0], cArgv.pointer, cEnv.pointer)
            _exit(127)
        }
        guard pid > 0 else { return nil }
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        setNonBlocking(master)
        let session = Session(tab: tab, pid: pid, fd: master, queue: queue)
        session.watch()
        return session
    }

    private func watch() {
        let read = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        // Strong on purpose: cancelling the sources at exit lets go of the session.
        read.setEventHandler { [self] in drain() }
        read.setCancelHandler { [fd] in close(fd) }
        read.resume()
        readSource = read

        let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        exit.setEventHandler { [self] in
            var status: Int32 = 0
            guard waitpid(pid, &status, WNOHANG) == pid else { return }
            drain()
            readSource?.cancel()
            master.stop()
            exitSource?.cancel()
            let code = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
            onExit?(code)
        }
        exit.resume()
        exitSource = exit
    }

    /// Passes on everything the program has written so far.
    private func drain() {
        // Once cancelled the descriptor is closed, and its number may
        // already belong to something else.
        guard readSource?.isCancelled == false else { return }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { return }
            memory.feed(buffer[0..<count])
            client?.send(KeeperWire.frame(.data, Data(buffer[0..<count])))
        }
    }

    func resize(cols: UInt16, rows: UInt16) {
        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(fd, TIOCSWINSZ, &size)
    }

    /// Sizes the terminal for the relay that just attached and asks the
    /// program to draw itself again, since the new window starts blank.
    func redraw(cols: UInt16, rows: UInt16) {
        client?.send(KeeperWire.frame(.data, memory.replay))
        resize(cols: cols, rows: rows)
        let group = tcgetpgrp(fd)
        if group > 0 { kill(-group, SIGWINCH) }
    }

    /// Ends the session the way closing a Ghostty tab does: hang up the
    /// terminal, then make sure.
    func hangUp() {
        guard !hungUp else { return }
        hungUp = true
        kill(-pid, SIGHUP)
        master.stop()
        readSource?.cancel()
        queue.asyncAfter(deadline: .now() + 3) { [pid, weak self] in
            guard self?.exitSource?.isCancelled == false else { return }
            kill(-pid, SIGKILL)
        }
    }
}

// MARK: - Client

/// One connection: an attached relay, or a one-off request from Workbench.
final class Client {
    let fd: Int32
    private let queue: DispatchQueue
    private let outbox: Outbox
    private var readSource: DispatchSourceRead?
    private var closed = false
    var inbox = Data()
    var request: KeeperWire.Request?
    var tab: String?
    var onBytes: (() -> Void)?
    var onClose: (() -> Void)?

    init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
        outbox = Outbox(fd: fd, queue: queue)
    }

    func start() {
        outbox.onFailure = { [unowned self] in close() }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [unowned self] in
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count > 0 {
                    inbox.append(contentsOf: buffer[0..<count])
                } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                    close()
                    return
                } else {
                    break
                }
            }
            onBytes?()
        }
        source.setCancelHandler { [fd] in Darwin.close(fd) }
        source.resume()
        readSource = source
    }

    func send(_ data: Data) {
        guard !closed else { return }
        outbox.send(data)
        // A relay that stops reading (a hung window) mustn't hold the
        // whole keeper's memory: let it go and let the next one redraw.
        if outbox.pending > 16 << 20 { close() }
    }

    func reply(_ reply: KeeperWire.Reply, thenClose: Bool) {
        var reply = reply
        reply.keeper = keeperInstance
        reply.loginSession = keeperLoginSession
        guard var line = try? JSONEncoder().encode(reply) else { return }
        line.append(UInt8(ascii: "\n"))
        send(line)
        if thenClose { closeWhenSent() }
    }

    func closeWhenSent() {
        outbox.whenEmpty { [weak self] in self?.close() }
    }

    func close() {
        guard !closed else { return }
        closed = true
        readSource?.cancel()
        outbox.stop()
        onClose?()
    }
}

// MARK: - Outbox

/// Bytes waiting for a non-blocking descriptor to take them.
final class Outbox {
    private let fd: Int32
    private let queue: DispatchQueue
    private var buffer = Data()
    private var source: DispatchSourceWrite?
    private var sourceRunning = false
    private var emptied: [() -> Void] = []
    var onFailure: (() -> Void)?

    var pending: Int { buffer.count }

    init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
    }

    func send(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        flush()
    }

    func whenEmpty(_ action: @escaping () -> Void) {
        if buffer.isEmpty { action() } else { emptied.append(action) }
    }

    func stop() {
        buffer.removeAll()
        emptied.removeAll()
        if let source {
            if !sourceRunning { source.resume() }
            source.cancel()
        }
        source = nil
    }

    private func flush() {
        while !buffer.isEmpty {
            let written = buffer.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if written > 0 {
                buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + written))
            } else if written < 0, errno == EAGAIN || errno == EINTR {
                waitForRoom()
                return
            } else {
                onFailure?()
                return
            }
        }
        if sourceRunning { source?.suspend(); sourceRunning = false }
        let actions = emptied
        emptied.removeAll()
        actions.forEach { $0() }
    }

    private func waitForRoom() {
        if source == nil {
            let made = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
            made.setEventHandler { [weak self] in self?.flush() }
            source = made
        }
        if !sourceRunning { source?.resume(); sourceRunning = true }
    }
}

// MARK: - Helpers

/// How Ghostty starts a shell on macOS, copied so a kept tab's shell is
/// set up the same: through login(1), as a login shell.
enum Shell {
    static var userShell: String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return "/bin/zsh"
    }

    static func loginArguments(command: String) -> [String] {
        guard let entry = getpwuid(getuid()) else {
            return ["/bin/bash", "--noprofile", "--norc", "-c", "exec -l \(command)"]
        }
        let user = String(cString: entry.pointee.pw_name)
        let home = String(cString: entry.pointee.pw_dir)
        var argv = ["/usr/bin/login"]
        if FileManager.default.fileExists(atPath: home + "/.hushlogin") { argv.append("-q") }
        argv += ["-flp", user, "/bin/bash", "--noprofile", "--norc", "-c", "exec -l \(command)"]
        return argv
    }

    /// Ghostty's shell integration (prompt marks, the folder you're in)
    /// for zsh and fish. Ghostty only sets it up when it can see the shell
    /// it's starting, and here it's starting the relay.
    static func addIntegration(for command: String, to env: inout [String: String]) {
        guard let resources = env["GHOSTTY_RESOURCES_DIR"] else { return }
        let program = command.split(separator: " ").first.map { String($0.split(separator: "/").last ?? "") } ?? ""
        switch program {
        case "zsh":
            let path = resources + "/shell-integration/zsh"
            guard FileManager.default.fileExists(atPath: path) else { return }
            if let old = env["ZDOTDIR"] { env["GHOSTTY_ZSH_ZDOTDIR"] = old }
            env["ZDOTDIR"] = path
        case "fish":
            let path = resources + "/shell-integration"
            guard FileManager.default.fileExists(atPath: path) else { return }
            env["GHOSTTY_SHELL_INTEGRATION_XDG_DIR"] = path
            let dirs = env["XDG_DATA_DIRS"] ?? "/usr/local/share:/usr/share"
            env["XDG_DATA_DIRS"] = path + ":" + dirs
        default:
            break
        }
    }
}

/// A NULL-terminated array of C strings that stays put until freed.
final class CStrings {
    let pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let count: Int

    init(_ strings: [String]) {
        count = strings.count
        pointer = .allocate(capacity: strings.count + 1)
        for (index, string) in strings.enumerated() { pointer[index] = strdup(string) }
        pointer[strings.count] = nil
    }

    deinit {
        for index in 0..<count { free(pointer[index]) }
        pointer.deallocate()
    }
}

func setNonBlocking(_ fd: Int32) {
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
}

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("\(stamp) \(message)\n".utf8))
}
