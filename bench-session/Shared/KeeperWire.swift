import Darwin
import Foundation

/// How Workbench, its tab relays, and the session keeper talk, over a Unix
/// socket. Compiled into both the app and the `bench-session` helper.
///
/// Every connection opens with one line of JSON, a `Request`, and the keeper
/// answers with one line, a `Reply`. An attach then carries `Frame`s both
/// ways until the session ends or the relay goes away.
nonisolated enum KeeperWire {
    /// Bumped whenever attaching changes, so a new Workbench never joins
    /// a keeper left running by an older one that reads it differently.
    /// Listing and ending sessions must keep working across versions, so
    /// a newer Workbench can clean up after an older keeper.
    static let version = 1

    struct Request: Codable {
        /// `quit` ends every session and then the keeper itself. Keepers
        /// from before it was added answer it with an error.
        enum Op: String, Codable { case attach, kill, list, quit }
        var v = KeeperWire.version
        var op: Op
        var tab: String?
        // For an attach that has to start the session.
        var cwd: String?
        /// The shell command line, as Ghostty would run it.
        var command: String?
        var env: [String: String]?
        /// Typed into the new shell once, like Ghostty's initial input.
        var input: String?
        var cols: UInt16?
        var rows: UInt16?
    }

    struct Reply: Codable {
        var v = KeeperWire.version
        var ok: Bool
        var error: String?
        /// For an attach: true if it started a new session, false if it
        /// joined one that was already running.
        var created: Bool?
        /// For a list: the tabs with a running session.
        var tabs: [String]?
        /// Different for every keeper that starts, so Workbench can tell
        /// when the one a tab was using has gone away.
        var keeper: String?
        /// The macOS login session the keeper runs in (see
        /// `loginSession()`). Nil from keepers older than this field.
        var loginSession: Int32?
    }

    /// This process's macOS login session, which a new one replaces each
    /// time you log out and back in. A process left over from an ended one
    /// can no longer look up user accounts, so `login` fails there.
    static func loginSession() -> Int32? {
        var info = auditinfo_addr()
        guard getaudit_addr(&info, Int32(MemoryLayout<auditinfo_addr>.size)) == 0 else { return nil }
        return info.ai_asid
    }

    /// Frames after an attach: a type byte, a 4-byte big-endian length, then
    /// the payload.
    enum Frame: UInt8 {
        /// Terminal bytes: typed input one way, program output the other.
        case data = 0
        /// The window's size: columns then rows, 2 bytes each.
        case resize = 1
        /// The session ended: its exit status, 4 bytes.
        case exit = 2
    }

    static func frame(_ type: Frame, _ payload: Data) -> Data {
        var out = Data(capacity: payload.count + 5)
        out.append(type.rawValue)
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    static func resizeFrame(cols: UInt16, rows: UInt16) -> Data {
        var payload = Data()
        var c = cols.bigEndian, r = rows.bigEndian
        withUnsafeBytes(of: &c) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &r) { payload.append(contentsOf: $0) }
        return frame(.resize, payload)
    }

    /// Takes every whole frame off the front of `buffer`.
    static func takeFrames(_ buffer: inout Data) -> [(Frame, Data)] {
        var frames: [(Frame, Data)] = []
        var offset = buffer.startIndex
        while buffer.endIndex - offset >= 5 {
            let length = buffer[(offset + 1)..<(offset + 5)].reduce(0) { $0 << 8 | Int($1) }
            guard buffer.endIndex - offset >= 5 + length else { break }
            if let type = Frame(rawValue: buffer[offset]) {
                frames.append((type, Data(buffer[(offset + 5)..<(offset + 5 + length)])))
            }
            offset += 5 + length
        }
        buffer.removeSubrange(buffer.startIndex..<offset)
        return frames
    }

    static func uint16(_ data: Data, at index: Int) -> UInt16 {
        let start = data.startIndex + index
        return UInt16(data[start]) << 8 | UInt16(data[start + 1])
    }

    // MARK: Sockets

    static func connect(to path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var address = unixAddress(path)
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, size) }
        }
        guard result == 0 else { close(fd); return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    static func unixAddress(_ path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8.prefix(MemoryLayout.size(ofValue: address.sun_path) - 1))
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }

    /// Writes all of `data` to a blocking descriptor.
    @discardableResult
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return true }
            var left = raw.count
            while left > 0 {
                let written = write(fd, pointer, left)
                if written < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    return false
                }
                left -= written
                pointer += written
            }
            return true
        }
    }

    static func send(_ fd: Int32, _ value: some Encodable) -> Bool {
        guard var line = try? JSONEncoder().encode(value) else { return false }
        line.append(UInt8(ascii: "\n"))
        return writeAll(fd, line)
    }

    /// Reads one line from a blocking descriptor, a byte at a time so
    /// nothing after it is taken.
    static func readLine(_ fd: Int32, limit: Int = 1 << 20) -> Data? {
        var line = Data()
        var byte: UInt8 = 0
        while line.count < limit {
            let count = read(fd, &byte, 1)
            if count < 0, errno == EINTR { continue }
            guard count == 1 else { return nil }
            if byte == UInt8(ascii: "\n") { return line }
            line.append(byte)
        }
        return nil
    }

    /// Sends a request and waits for the reply, giving up after `timeout`.
    static func ask(_ path: String, _ request: Request, timeout: TimeInterval = 2) -> Reply? {
        guard let fd = connect(to: path) else { return nil }
        defer { close(fd) }
        var time = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
        guard send(fd, request), let line = readLine(fd) else { return nil }
        return try? JSONDecoder().decode(Reply.self, from: line)
    }
}
