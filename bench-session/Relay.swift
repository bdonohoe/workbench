import Darwin
import Foundation

/// `bench-session attach`: what a kept tab's Ghostty terminal runs in
/// place of the shell. It joins the tab's session in the keeper, starting
/// it if needed, and passes bytes both ways untouched, so titles, progress,
/// colors, and keys all work as if the shell were right there.
///
/// When Workbench quits, Ghostty hangs up on this and it ends. The session
/// in the keeper carries on.
enum Relay {
    /// Variables that describe this process, not the shell to start.
    private static let ownVariables: Set<String> = ["SHLVL", "_", "PWD", "OLDPWD", inputVariable]
    /// What to type into a new session, from Workbench.
    static let inputVariable = "BENCH_SESSION_INPUT"

    private static var original = termios()
    private static var isRaw = false

    static func run(socket path: String, tab: String, command: String) -> Never {
        signal(SIGPIPE, SIG_IGN)
        let environment = ProcessInfo.processInfo.environment
        var env = environment.filter { !ownVariables.contains($0.key) }
        var size = winsize()
        _ = ioctl(STDIN_FILENO, TIOCGWINSZ, &size)

        guard let fd = KeeperWire.connect(to: path) else {
            fallBack("Workbench's session keeper isn't running.", command: command, env: &env)
        }
        var request = KeeperWire.Request(op: .attach, tab: tab)
        request.cwd = FileManager.default.currentDirectoryPath
        request.command = command
        request.env = env
        request.input = environment[inputVariable]
        request.cols = size.ws_col > 0 ? size.ws_col : 80
        request.rows = size.ws_row > 0 ? size.ws_row : 24
        guard KeeperWire.send(fd, request), let line = KeeperWire.readLine(fd),
              let reply = try? JSONDecoder().decode(KeeperWire.Reply.self, from: line) else {
            fallBack("Workbench's session keeper didn't answer.", command: command, env: &env)
        }
        guard reply.ok else {
            fallBack("Workbench's session keeper said: \(reply.error ?? "no").", command: command, env: &env)
        }

        makeRaw()
        signal(SIGWINCH, SIG_IGN)
        let resize = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
        resize.setEventHandler {
            var size = winsize()
            guard ioctl(STDIN_FILENO, TIOCGWINSZ, &size) == 0 else { return }
            KeeperWire.writeAll(fd, KeeperWire.resizeFrame(cols: size.ws_col, rows: size.ws_row))
        }
        resize.resume()

        let input = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
        input.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 65_536)
            let count = read(STDIN_FILENO, &buffer, buffer.count)
            if count > 0 {
                KeeperWire.writeAll(fd, KeeperWire.frame(.data, Data(buffer[0..<count])))
            } else if count == 0 || errno != EINTR {
                // The window is gone. The session isn't.
                finish(0)
            }
        }
        input.resume()

        var pending = Data()
        let output = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        output.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 65_536)
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else {
                if count < 0, errno == EINTR { return }
                restore()
                let note = "\r\n[Workbench's session keeper stopped. Workbench will start this tab again.]\r\n"
                KeeperWire.writeAll(STDOUT_FILENO, Data(note.utf8))
                exit(1)
            }
            pending.append(contentsOf: buffer[0..<count])
            for (type, payload) in KeeperWire.takeFrames(&pending) {
                switch type {
                case .data:
                    KeeperWire.writeAll(STDOUT_FILENO, payload)
                case .exit:
                    let status = payload.count >= 4 ? payload.prefix(4).reduce(Int32(0)) { $0 << 8 | Int32($1) } : 0
                    finish(status)
                case .resize:
                    break
                }
            }
        }
        output.resume()
        // Keep the sources alive for the life of the process.
        withExtendedLifetime((resize, input, output)) { dispatchMain() }
    }

    private static func finish(_ status: Int32) -> Never {
        restore()
        exit(status)
    }

    /// Hands each key straight to the keeper: the session's own terminal
    /// does the echoing, line editing, and Control-C.
    private static func makeRaw() {
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { return }
        var raw = original
        cfmakeraw(&raw)
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        isRaw = true
    }

    private static func restore() {
        if isRaw { tcsetattr(STDIN_FILENO, TCSANOW, &original) }
    }

    /// Runs the shell here, like an ordinary tab, so the tab still works.
    private static func fallBack(_ problem: String, command: String, env: inout [String: String]) -> Never {
        let note = "\(problem) This tab won't survive a restart.\n"
        FileHandle.standardError.write(Data(note.utf8))
        Shell.addIntegration(for: command, to: &env)
        let argv = CStrings(["/bin/bash", "--noprofile", "--norc", "-c", "exec -l \(command)"])
        let envp = CStrings(env.map { "\($0.key)=\($0.value)" })
        execve("/bin/bash", argv.pointer, envp.pointer)
        exit(127)
    }
}
