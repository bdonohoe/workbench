import BenchKit
import Foundation

/// Asks an agent something in the background, on the account you pass,
/// for features like recaps and Brain Dump.
///
/// The agent's command-line tool is run with no tools, settings or saved
/// session (`AgentBackground.oneShot`), from an empty folder, so it only
/// reads what it's given, can't change anything, and leaves nothing in
/// your session history. Since there's no transcript for the Usage page to
/// read, each call reports its own tokens to `UsageLedger`.
enum AgentRunner {
    enum Failure: Error, Equatable {
        case notInstalled
        case couldNotStart
        case timedOut
        case failed(status: Int32)
        case emptyReply
    }

    /// Set from the timeout timer and read after the process exits.
    private nonisolated final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    nonisolated static func ask(_ input: String, instructions: String, model: BackgroundModel = .small, timeout: TimeInterval,
                                profile: ClaudeProfile, agent: AgentID = Agents.backgroundAgent) -> String? {
        try? run(input, instructions: instructions, model: model, timeout: timeout, profile: profile, agent: agent).get()
    }

    /// Like `ask`, but says why it failed.
    nonisolated static func run(_ input: String, instructions: String, model: BackgroundModel = .small, timeout: TimeInterval,
                                profile: ClaudeProfile, agent: AgentID = Agents.backgroundAgent) -> Result<String, Failure> {
        let background = Agents.background(agent)
        Tools.resolveIfNeeded()
        guard let claude = Tools.path(background.program) else { return .failure(.notInstalled) }
        let command = background.oneShot(instructions: instructions, model: model, profile: profile)
        let folder = BenchPaths.support.appendingPathComponent("recap-runs", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = command.arguments
        process.currentDirectoryURL = folder
        var environment = Tools.environment
        command.apply(to: &environment)
        process.environment = environment
        let inputPipe = Pipe(), output = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return .failure(.couldNotStart) }
        inputPipe.fileHandleForWriting.write(Data(input.utf8))
        try? inputPipe.fileHandleForWriting.close()
        let timedOut = Flag()
        let timer = DispatchWorkItem {
            if process.isRunning {
                timedOut.set()
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        if timedOut.isSet { return .failure(.timedOut) }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            return .failure(.failed(status: process.terminationStatus))
        }
        let printed = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let reply = background.oneShotReply(in: printed) else {
            return printed.isEmpty ? .failure(.emptyReply) : .success(printed)
        }
        if reply.isError { return .failure(.failed(status: process.terminationStatus)) }
        if let usage = reply.usage, let model = reply.model {
            let tally = background.tally(usage: usage, model: model)
            Task { @MainActor in UsageLedger.shared.recordBackground(tally, model: model, profile: profile) }
        }
        return reply.text.isEmpty ? .failure(.emptyReply) : .success(reply.text)
    }
}
