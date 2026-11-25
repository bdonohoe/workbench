import Compression
import Foundation
import Testing
@testable import Bench

/// Telling Workbench's own stray `default.profraw` files from anyone
/// else's, so only ours are cleaned out of a project.
struct ProfrawLitterTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bench-profraw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A raw profile: the magic, some header bytes, then the function
    /// names as a zlib stream, the way LLVM writes them.
    private func profile(names: String, compressed: Bool = true) -> Data {
        var data = Data([0x81, 0x72, 0x66, 0x6F, 0x72, 0x70, 0x6C, 0xFF])
        data.append(Data(repeating: 0, count: 80))
        data.append(Data([0x10, 0x20, 0x30]))
        let plain = Data(names.utf8)
        if compressed {
            data.append(Data([0x78, 0x9C]))
            data.append(deflate(plain))
            data.append(Data([0, 0, 0, 0]))
        } else {
            data.append(plain)
        }
        data.append(Data(repeating: 0, count: 16))
        return data
    }

    private func deflate(_ input: Data) -> Data {
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: input.count + 1024)
        defer { buffer.deallocate() }
        let count = input.withUnsafeBytes { source in
            compression_encode_buffer(buffer, input.count + 1024, source.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_ZLIB)
        }
        return Data(bytes: buffer, count: count)
    }

    @Test func recognizesTheHelpersProfile() throws {
        let file = try folder().appendingPathComponent("default.profraw")
        try profile(names: "/Users/me/Apps/Bench/bench-session/main.swift:$s13bench_session6KeeperC4mainyyF").write(to: file)
        #expect(ProfrawLitter.isWorkbenchLitter(at: file))
    }

    @Test func recognizesPlainNamesToo() throws {
        let file = try folder().appendingPathComponent("default.profraw")
        try profile(names: "$s13bench_session5RelayC", compressed: false).write(to: file)
        #expect(ProfrawLitter.isWorkbenchLitter(at: file))
    }

    @Test func leavesOtherProgramsProfilesAlone() throws {
        let folder = try folder()
        let theirs = folder.appendingPathComponent("default.profraw")
        try profile(names: "/Users/me/Code/Thing/Sources/main.swift:$s5Thing4mainyyF").write(to: theirs)
        #expect(!ProfrawLitter.isWorkbenchLitter(at: theirs))
        #expect(!ProfrawLitter.sweep(root: folder))
        #expect(FileManager.default.fileExists(atPath: theirs.path))

        let notAProfile = folder.appendingPathComponent("notes.profraw")
        try Data("bench_session wrote this, honest".utf8).write(to: notAProfile)
        #expect(!ProfrawLitter.isWorkbenchLitter(at: notAProfile))
        #expect(!ProfrawLitter.isWorkbenchLitter(at: folder.appendingPathComponent("missing.profraw")))
    }

    @Test func sweepRemovesOnlyOurs() throws {
        let folder = try folder()
        let ours = folder.appendingPathComponent("default.profraw")
        try profile(names: "$s13bench_session8TerminalC").write(to: ours)
        #expect(ProfrawLitter.sweep(root: folder))
        #expect(!FileManager.default.fileExists(atPath: ours.path))
        #expect(!ProfrawLitter.sweep(root: folder))
    }
}
