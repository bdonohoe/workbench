import BenchKit
import Foundation
import Observation

/// `/btw` side questions, one per Claude tab at a time.
///
/// Claude Code answers its own `/btw` in a pop-up over the terminal and
/// writes nothing to the transcript, so the chat couldn't show it. Bench
/// asks instead, with a one-off `claude -p` that resumes a copy of the
/// tab's conversation:
///
/// - `--fork-session` and `--no-session-persistence`: the copy gets its
///   own id and is never saved, so the tab's conversation, its history,
///   and Resume never see it.
/// - The tab's model and Claude Code's usual tools: the request then
///   starts the same way the tab's own requests do, so most of it is read
///   from the prompt cache (about a cent on a long conversation, against
///   tens of cents without). The prompt asks Claude not to use the tools,
///   and if it starts to call one anyway the run is killed on the spot,
///   before the call can happen: a tool you've allowed ahead of time would
///   otherwise run, in the project's folder, even in a one-turn `dontAsk`
///   run. Denying the tools in settings takes them off the list, which
///   loses the cache.
/// - No hooks: Bench's own would report the copy as if it were the tab.
///
/// It's a separate process, so it works while the tab is busy, even in
/// the middle of a tool call.
@Observable
final class SideQuestions {
    static let shared = SideQuestions()

    /// The side question showing in each tab's chat, by tab.
    private(set) var byTab: [UUID: SideQuestion] = [:]
    /// Called on every change to a tab's side question, so the companion
    /// server can pass it on.
    @ObservationIgnored var onChange: ((_ tabID: UUID) -> Void)?

    @ObservationIgnored private var runs: [UUID: Process] = [:]

    /// What to call each tab's agent in a message.
    private var wording: [UUID: AgentWording] = [:]

    private func words(_ tabID: UUID) -> AgentWording { wording[tabID] ?? Agents.standard.wording }

    /// The longest one gets before it's stopped.
    static let timeout: TimeInterval = 180

    /// Asks `question` about a tab's conversation, in place of the side
    /// question it showed before. Returns why it can't.
    @discardableResult
    func ask(_ question: String, id: UUID = UUID(), tabID: UUID, terminals: TerminalManager, fromPhone: Bool = false) -> String? {
        wording[tabID] = terminals.existingSession(tabID)?.agent?.wording
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return "Type a question after /btw." }
        guard let session = terminals.existingSession(tabID), session.isAgent else { return "That isn't a \(words(tabID).name) tab." }
        guard session.remoteHost == nil else { return "Side questions only work with \(words(tabID).name) on this Mac." }
        guard let transcript = CompanionSnapshots.transcriptPath(tabID: tabID, terminals: terminals),
              FileManager.default.fileExists(atPath: transcript) else {
            return "Send \(words(tabID).name) a message first. A side question is about the conversation so far."
        }
        guard let provider = session.agent else { return "That isn't a \(words(tabID).name) tab." }
        let background = Agents.background(provider.id)
        Tools.resolveIfNeeded()
        guard let claude = Tools.path(background.program) else { return "\(provider.productName) isn't installed." }
        let sessionID = URL(fileURLWithPath: transcript).deletingPathExtension().lastPathComponent
        let folder = TranscriptFolder.read(transcript: transcript) ?? terminals.projectPath(forTab: tabID)
        guard let folder, FileManager.default.fileExists(atPath: folder) else {
            return "The folder this conversation ran in is gone."
        }

        stop(tabID: tabID)
        let asked = SideQuestion(id: id, question: question)
        set(asked, tabID: tabID)

        let running = session.claudeState == .working ? session.details?.action : nil
        let profile = ClaudeAccounts.shared.profile(forTranscript: transcript)
        let command = background.sideQuestion(SideQuestion.prompt(for: question, running: running), sessionID: sessionID,
                                              model: session.usage?.model, profile: profile)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = command.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: folder)
        var environment = Tools.environment
        command.apply(to: &environment)
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output

        let lines = LineBuffer()
        output.fileHandleForReading.readabilityHandler = { [weak process] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            var complete = data.isEmpty ? lines.finish() : lines.add(data)
            // Killed here, on the pipe's own thread, the moment a tool call
            // starts: its arguments are still arriving, so it hasn't run.
            // Not left for the main thread, which may be busy.
            if let call = complete.firstIndex(where: background.startsToolCall) {
                if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
                handle.readabilityHandler = nil
                complete = Array(complete[...call])
            }
            guard !complete.isEmpty else { return }
            Task { @MainActor in self.read(complete, id: id, tabID: tabID, profile: profile, background: background) }
        }
        process.terminationHandler = { process in
            let status = process.terminationStatus, reason = process.terminationReason
            Task { @MainActor in
                // What's left in the pipe comes first.
                try? await Task.sleep(for: .milliseconds(100))
                self.ended(id: id, tabID: tabID, status: status, reason: reason)
            }
        }
        do { try process.run() } catch {
            output.fileHandleForReading.readabilityHandler = nil
            set(SideQuestion(id: id, question: question, state: .failed, problem: "\(words(tabID).product) couldn't start."), tabID: tabID)
            return nil
        }
        runs[tabID] = process
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) { [weak self, weak process] in
            guard let self, let process, process.isRunning, runs[tabID] === process else { return }
            process.terminate()
            update(id: id, tabID: tabID) {
                // An answer that's in stays, however long the exit takes.
                guard $0.state == .asking else { return }
                $0.state = .failed
                $0.problem = "\(words(tabID).name) took too long to answer."
            }
        }
        Analytics.capture(.sideQuestionAsked, ["from_phone": fromPhone])
        return nil
    }

    /// Closes a tab's side question, stopping it if it's still being
    /// answered. With an id, only if that's the one showing.
    func dismiss(tabID: UUID, id: UUID? = nil) {
        guard let current = byTab[tabID], id == nil || current.id == id else { return }
        stop(tabID: tabID)
        set(nil, tabID: tabID)
    }

    /// Lets go of tabs that are gone.
    func forget(except tabIDs: Set<UUID>) {
        for tabID in Set(byTab.keys).union(runs.keys) where !tabIDs.contains(tabID) {
            stop(tabID: tabID)
            byTab[tabID] = nil
        }
    }

    private func stop(tabID: UUID) {
        guard let process = runs.removeValue(forKey: tabID) else { return }
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }

    private func read(_ lines: [String], id: UUID, tabID: UUID, profile: ClaudeProfile, background: any AgentBackground) {
        for line in lines {
            switch background.sideQuestionEvent(in: line) {
            case .text(let more):
                update(id: id, tabID: tabID) { $0.answer += more }
            case .finished(let text, let isError):
                update(id: id, tabID: tabID) {
                    // A reply that stopped to use a tool still said
                    // something first, which is the answer.
                    if !text.isEmpty { $0.answer = text }
                    if $0.answer.isEmpty {
                        $0.state = .failed
                        $0.problem = isError ? "\(words(tabID).name) couldn't answer that here." : "\(words(tabID).name) didn't say anything."
                    } else {
                        $0.state = .answered
                    }
                }
                if let reply = background.oneShotReply(in: line), let usage = reply.usage, let model = reply.model {
                    UsageLedger.shared.recordBackground(background.tally(usage: usage, model: model), model: model, profile: profile)
                }
            case .toolCall:
                // The run is already killed. What Claude said first, if
                // anything, is the answer.
                update(id: id, tabID: tabID) {
                    guard $0.state == .asking else { return }
                    if $0.answer.isEmpty {
                        $0.state = .failed
                        $0.problem = "\(words(tabID).name) tried to do something instead of answering. Side questions can only be answered from the conversation."
                    } else {
                        $0.state = .answered
                    }
                }
                return
            case nil:
                continue
            }
        }
    }

    private func ended(id: UUID, tabID: UUID, status: Int32, reason: Process.TerminationReason) {
        if let process = runs[tabID], !process.isRunning { runs[tabID] = nil }
        update(id: id, tabID: tabID) {
            guard $0.state == .asking else { return }
            if !$0.answer.isEmpty {
                $0.state = .answered
            } else {
                $0.state = .failed
                $0.problem = reason == .exit && status == 0 ? "\(words(tabID).name) didn't say anything." : "\(words(tabID).product) stopped before answering."
            }
        }
    }

    /// Changes the side question with this id, if it's still the one showing.
    private func update(id: UUID, tabID: UUID, _ change: (inout SideQuestion) -> Void) {
        guard var question = byTab[tabID], question.id == id else { return }
        let before = question
        change(&question)
        if question != before { set(question, tabID: tabID) }
    }

    private func set(_ question: SideQuestion?, tabID: UUID) {
        byTab[tabID] = question
        onChange?(tabID)
    }
}

/// Splits a process's output into lines as it arrives, from the pipe's
/// own thread.
private nonisolated final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()

    /// The lines this data completes.
    func add(_ data: Data) -> [String] {
        lock.withLock {
            pending.append(data)
            guard let last = pending.lastIndex(of: UInt8(ascii: "\n")) else { return [] }
            let complete = pending[..<last]
            pending = Data(pending[pending.index(after: last)...])
            return complete.split(separator: UInt8(ascii: "\n")).map { String(decoding: $0, as: UTF8.self) }
        }
    }

    /// Whatever's left, once the output has ended.
    func finish() -> [String] {
        lock.withLock {
            defer { pending = Data() }
            return pending.isEmpty ? [] : [String(decoding: pending, as: UTF8.self)]
        }
    }
}
