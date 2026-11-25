import AppKit
import BenchKit
import Foundation
import Network
import Observation

/// Picks up prompts the phone queued on the relay while this Mac was
/// asleep or offline, and starts each as a new agent, oldest first, with
/// no asking. Checks at launch, on wake, when the network comes back and
/// every five minutes, only while the iPhone companion is on.
///
/// Taken prompts are saved to `pending.json` before any starts, so a crash
/// partway through doesn't lose them: the next check starts what's left.
/// Only then does the Mac ack them, so the relay stops handing them back.
/// Until it does, each take hands them over again, and `started.json`
/// (ids started in the last two days) keeps one from starting twice.
/// A prompt that can't start goes to `failed.json` with a plain reason,
/// to be retried in another project or thrown away.
@MainActor @Observable
final class OfflineQueue {
    struct FailedPrompt: Codable, Identifiable, Hashable {
        var prompt: QueuedPrompt
        var reason: String
        var id: UUID { prompt.id }
    }

    /// The reason a non-git project gives, from the app's start closure.
    struct NotGit: Error, LocalizedError {
        var errorDescription: String? { "Queued prompts need a git project." }
    }

    /// Whether a folder is in a git repository: it or a folder above it
    /// has a `.git` entry. A worktree's `.git` is a file, so either counts.
    nonisolated static func isGitFolder(_ folder: URL) -> Bool {
        var path = folder.standardizedFileURL.path
        while true {
            if FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git")) { return true }
            let parent = (path as NSString).deletingLastPathComponent
            if parent.isEmpty || parent == path { return false }
            path = parent
        }
    }

    private static let interval: TimeInterval = 300
    /// How long a started id is remembered. The relay hands back an
    /// unacked prompt for a day at most.
    private static let rememberStarted: TimeInterval = 2 * 86_400
    private static let unlockReason = "Couldn't be unlocked. It may be from an older pairing code."

    private(set) var failed: [FailedPrompt]
    /// Taken from the relay but not started yet.
    private(set) var pending: [QueuedPrompt]
    private(set) var isChecking = false
    /// Whether the "couldn't start" sheet is showing. The notification sets it.
    var showsFailedPrompts = false

    /// Tells the paired phone. Set by the app.
    @ObservationIgnored var notifyPhone: ((_ title: String, _ body: String, _ projectID: UUID?, _ tabID: UUID?) -> Void)?
    /// Called with the prompts that just failed, for a notification here.
    @ObservationIgnored var onFailure: (([FailedPrompt]) -> Void)?
    /// Called with each file's name after it's written. Tests only.
    @ObservationIgnored var didWrite: ((String) -> Void)?

    @ObservationIgnored private let token: () -> String?
    @ObservationIgnored private let isEnabled: () -> Bool
    @ObservationIgnored private let relayURL: URL?
    @ObservationIgnored private let startAgent: (QueuedPrompt) async throws -> (project: UUID, tab: UUID?)?
    @ObservationIgnored private let folder: URL
    @ObservationIgnored private let transport: QueueRelay.Transport
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var wasOnline = false
    /// Prompts being started right now. A check, drain or retry that
    /// overlaps another skips these, so none starts twice.
    @ObservationIgnored private var inFlight: Set<UUID> = []
    /// Ids started (or thrown away) lately, and when.
    @ObservationIgnored private var started: [UUID: Date]
    /// Ids saved here but not acked yet, by mailbox. Tried again each check.
    @ObservationIgnored private var unacked: [String: [UUID]]

    init(token: @escaping () -> String?, isEnabled: @escaping () -> Bool, relayURL: URL?,
         start: @escaping (QueuedPrompt) async throws -> (project: UUID, tab: UUID?)?, folder: URL,
         transport: @escaping QueueRelay.Transport = { try await URLSession.shared.data(for: $0) }) {
        self.token = token
        self.isEnabled = isEnabled
        self.relayURL = relayURL
        self.startAgent = start
        self.folder = folder
        self.transport = transport
        // With no relay (a debug build without BENCH_TEST_OFFLINE_QUEUE)
        // the files are never read or written, since they're the real app's.
        let files = relayURL != nil
        pending = files ? Self.load([QueuedPrompt].self, from: folder.appendingPathComponent("pending.json")) ?? [] : []
        failed = files ? Self.load([FailedPrompt].self, from: folder.appendingPathComponent("failed.json")) ?? [] : []
        started = files ? Self.load([UUID: Date].self, from: folder.appendingPathComponent("started.json")) ?? [:] : [:]
        unacked = files ? Self.load([String: [UUID]].self, from: folder.appendingPathComponent("unacked.json")) ?? [:] : [:]
        let cutoff = Date().addingTimeInterval(-Self.rememberStarted)
        started = started.filter { $0.value > cutoff }
    }

    /// Checks now, then on wake, when the network comes back and every
    /// five minutes. The app calls this at launch.
    func start() {
        guard relayURL != nil, timer == nil else { return }
        Task { await check() }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in await self?.networkChanged(online: online) }
        }
        monitor.start(queue: DispatchQueue(label: "OfflineQueue.path"))
        pathMonitor = monitor
    }

    /// Checks when the network comes back, not on every change.
    private func networkChanged(online: Bool) async {
        let cameBack = online && !wasOnline
        wasOnline = online
        if cameBack { await check() }
    }

    // MARK: Checking

    /// Starts anything left from last time, then takes what's waiting on
    /// the relay and starts it, oldest first. A relay problem changes
    /// nothing: the prompts wait there for the next check.
    func check() async {
        guard !isChecking, isEnabled(), let token = token(), let relayURL else { return }
        isChecking = true
        defer { isChecking = false }
        var failures: [FailedPrompt] = []
        for prompt in pending.sorted(by: { $0.queuedAt < $1.queuedAt }) {
            if let failure = await run(prompt) { failures.append(failure) }
        }
        failures += await takeAndStart(token: token, url: relayURL)
        if !failures.isEmpty { onFailure?(failures) }
    }

    /// Takes whatever is left in the mailbox of a pairing code that's
    /// being replaced, so it isn't stranded there.
    func drain(oldToken: String) async {
        guard isEnabled(), let relayURL else { return }
        let failures = await takeAndStart(token: oldToken, url: relayURL)
        if !failures.isEmpty { onFailure?(failures) }
    }

    private func takeAndStart(token: String, url: URL) async -> [FailedPrompt] {
        let mailbox = QueueSeal.mailboxID(token: token)
        let items: [QueueItem]
        do {
            items = try await QueueRelay(url: url, mailbox: mailbox, transport: transport).take()
        } catch {
            return []
        }
        guard !items.isEmpty else {
            await sendAcks(url: url)
            return []
        }
        // A take hands back anything not acked yet, so some of these may
        // already be here, or already started.
        let known = Set(pending.map(\.id)).union(failed.map(\.id)).union(started.keys).union(inFlight)
        let key = QueueSeal.key(token: token)
        var opened: [QueuedPrompt] = []
        var failures: [FailedPrompt] = []
        for item in items where !known.contains(item.id) {
            if let prompt = QueueSeal.open(item.sealed, key: key, mailbox: mailbox) {
                opened.append(prompt)
            } else {
                let blank = QueuedPrompt(id: item.id, projectID: UUID(), projectName: "", prompt: "", queuedAt: item.addedAt, device: "")
                failures.append(FailedPrompt(prompt: blank, reason: Self.unlockReason))
            }
        }
        // Saved before the ack and before any starts, so none are lost if
        // Workbench stops partway.
        failed += failures
        pending += opened
        var waiting = unacked[mailbox] ?? []
        waiting += items.map(\.id).filter { !waiting.contains($0) }
        unacked[mailbox] = waiting
        save()
        await sendAcks(url: url)
        for prompt in opened.sorted(by: { $0.queuedAt < $1.queuedAt }) {
            if let failure = await run(prompt) { failures.append(failure) }
        }
        return failures
    }

    /// Tells the relay which prompts are saved here, so it stops handing
    /// them back. What doesn't go through is tried on the next check.
    private func sendAcks(url: URL) async {
        for (mailbox, all) in unacked.sorted(by: { $0.key < $1.key }) where !all.isEmpty {
            // The relay takes 100 ids at a time.
            let ids = Array(all.prefix(100))
            do {
                try await QueueRelay(url: url, mailbox: mailbox, transport: transport).ack(ids: ids)
            } catch {
                continue
            }
            // Ids added while the ack was out stay for the next one.
            unacked[mailbox]?.removeAll { ids.contains($0) }
            if unacked[mailbox]?.isEmpty == true { unacked[mailbox] = nil }
            save()
        }
    }

    /// Starts one pending prompt. Returns what failed, already saved.
    private func run(_ prompt: QueuedPrompt) async -> FailedPrompt? {
        if started[prompt.id] != nil {
            // Started before Workbench stopped, and not cleared from pending.
            pending.removeAll { $0.id == prompt.id }
            save()
            return nil
        }
        guard inFlight.insert(prompt.id).inserted else { return nil }
        defer { inFlight.remove(prompt.id) }
        let reason: String
        do {
            if let started = try await startAgent(prompt) {
                self.started[prompt.id] = Date()
                pending.removeAll { $0.id == prompt.id }
                failed.removeAll { $0.id == prompt.id }
                save()
                notifyPhone?("Started from your queue", "\(prompt.projectName): \(prompt.prompt.prefix(80))", started.project, started.tab)
                return nil
            }
            reason = "\(prompt.projectName) isn't in Workbench anymore."
        } catch {
            reason = error.localizedDescription
        }
        let failure = FailedPrompt(prompt: prompt, reason: reason)
        pending.removeAll { $0.id == prompt.id }
        failed.removeAll { $0.id == prompt.id }
        failed.append(failure)
        save()
        return failure
    }

    // MARK: Failed prompts

    /// Starts a failed prompt in another project.
    func retry(_ id: UUID, in projectID: UUID) async {
        guard var prompt = failed.first(where: { $0.id == id })?.prompt, !prompt.prompt.isEmpty else { return }
        prompt.projectID = projectID
        failed.removeAll { $0.id == id }
        pending.append(prompt)
        save()
        // No notification: the sheet that started this shows the outcome.
        _ = await run(prompt)
    }

    func discard(_ id: UUID) {
        // Counted as started, so a take that hands it back can't start it.
        started[id] = Date()
        failed.removeAll { $0.id == id }
        save()
    }

    // MARK: Saving

    /// Failed and started go first: a prompt in both pending and one of
    /// those is safe (the next check sorts it out), but one dropped from
    /// pending before it's written elsewhere is lost or started twice.
    private func save() {
        guard relayURL != nil else { return }
        let cutoff = Date().addingTimeInterval(-Self.rememberStarted)
        started = started.filter { $0.value > cutoff }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        write(failed, to: "failed.json")
        write(started, to: "started.json")
        write(unacked, to: "unacked.json")
        write(pending, to: "pending.json")
    }

    private func write<T: Encodable>(_ value: T, to name: String) {
        guard (try? CompanionCoding.encoder.encode(value).write(to: folder.appendingPathComponent(name), options: .atomic)) != nil else { return }
        didWrite?(name)
    }

    private static func load<T: Decodable>(_ type: T.Type, from file: URL) -> T? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? CompanionCoding.decoder.decode(type, from: data)
    }
}
