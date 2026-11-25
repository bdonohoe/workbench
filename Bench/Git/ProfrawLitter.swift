import Compression
import Foundation

/// `default.profraw` files that Workbench itself left in project folders.
///
/// Builds before 1.1.2 were compiled with coverage instrumentation, so the
/// bench-session helper behind every tab wrote LLVM profiling data into its
/// working directory, the project folder, each time it exited. That file
/// then sat in the project's Changes as an untracked file. This recognizes
/// those files by their contents, so only Workbench's own are removed:
/// the names inside a profile say which program wrote it.
nonisolated enum ProfrawLitter {
    static let fileName = "default.profraw"

    /// The raw profile magic: "\x81rforpl\xff" on little-endian machines.
    private static let magic: [UInt8] = [0x81, 0x72, 0x66, 0x6F, 0x72, 0x70, 0x6C, 0xFF]
    /// What Workbench's own symbols look like inside a profile: the helper's
    /// module and source folder, and the app's module.
    private static let needles = ["bench_session", "bench-session/", "$s5Bench"].map { Data($0.utf8) }
    /// Profiles are small; one bigger than this isn't ours.
    private static let maxSize = 8 << 20

    /// True when the file is a raw LLVM profile written by Workbench.
    static func isWorkbenchLitter(at url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int, size > magic.count, size <= maxSize,
              let data = try? Data(contentsOf: url),
              data.prefix(magic.count).elementsEqual(magic) else { return false }
        return names(in: data).contains { text in needles.contains { text.range(of: $0) != nil } }
    }

    /// Removes the project's `default.profraw` if Workbench wrote it.
    /// Returns true when a file was removed.
    @discardableResult
    static func sweep(root: URL) -> Bool {
        let file = root.appendingPathComponent(fileName)
        guard isWorkbenchLitter(at: file) else { return false }
        do {
            try FileManager.default.removeItem(at: file)
            NSLog("Bench: removed \(fileName) that an earlier Workbench left in \(root.path)")
            return true
        } catch {
            return false
        }
    }

    /// The profile's function names, which LLVM stores either plain or as
    /// zlib streams. Returns the raw bytes plus every stream that inflates.
    private static func names(in data: Data) -> [Data] {
        var found = [data]
        let bytes = [UInt8](data)
        var index = 0
        while index + 1 < bytes.count {
            // A zlib stream starts with 0x78 and one of a few flag bytes.
            if bytes[index] == 0x78, [0x01, 0x5E, 0x9C, 0xDA].contains(bytes[index + 1]),
               let inflated = inflate(bytes[(index + 2)...]) {
                found.append(inflated)
                index += max(inflated.count / 8, 1)
            } else {
                index += 1
            }
        }
        return found
    }

    /// Inflates a raw deflate stream, or nil if the bytes aren't one.
    private static func inflate(_ input: ArraySlice<UInt8>) -> Data? {
        let limit = 4 << 20
        var output = Data()
        var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>.allocate(capacity: 1), dst_size: 0,
                                        src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(&stream) }
        let chunk = 64 << 10
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buffer.deallocate() }
        return Array(input).withUnsafeBufferPointer { source -> Data? in
            stream.src_ptr = source.baseAddress!
            stream.src_size = source.count
            while true {
                stream.dst_ptr = buffer
                stream.dst_size = chunk
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                output.append(buffer, count: chunk - stream.dst_size)
                switch status {
                case COMPRESSION_STATUS_END: return output.isEmpty ? nil : output
                case COMPRESSION_STATUS_OK:
                    if output.count > limit || (stream.src_size == 0 && stream.dst_size != 0) { return output.isEmpty ? nil : output }
                default: return nil
                }
            }
        }
    }
}
