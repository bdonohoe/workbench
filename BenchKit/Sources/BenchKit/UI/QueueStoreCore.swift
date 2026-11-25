import Foundation
import Synchronization

/// The phone's own copy of a prompt it queued, and the mailbox it went to.
public struct LocalQueued: Codable, Sendable, Hashable, Identifiable {
    public enum Status: String, Codable, Sendable {
        /// Not on the relay yet. Sent again on the next refresh.
        case unsent
        /// On the relay, waiting for the Mac.
        case waiting
        /// The relay let it go before the Mac took it.
        case expired
    }

    public var prompt: QueuedPrompt
    public var mailbox: String
    public var status: Status
    public var id: UUID { prompt.id }

    public init(prompt: QueuedPrompt, mailbox: String, status: Status) {
        self.prompt = prompt
        self.mailbox = mailbox
        self.status = status
    }
}

/// The prompts this phone queued for one Mac, kept in step with the relay.
/// A copy stays here until the Mac takes it, so the phone can say what's
/// waiting, what hasn't gone out, and what expired.
public actor QueueStoreCore {
    /// The relay refuses sealed prompts longer than this.
    static let maxSealed = 32_768
    /// The relay answers a list about at most this many ids.
    static let maxListed = 100

    /// A prompt deleted here that may still be on the relay. Kept until
    /// the relay confirms, so the Mac never starts something you deleted.
    struct Deleting: Codable, Hashable {
        var id: UUID
        var mailbox: String
    }

    private struct Saved: Codable {
        var copies: [LocalQueued]
        var deleting: [Deleting]
    }

    private let file: URL
    private let relay: @Sendable (String) -> QueueRelay
    private var copies: [LocalQueued]
    private var deleting: [Deleting]
    /// Set when this Mac's file moved to a new host. A store someone still
    /// holds then stops saving, so it can't bring the old file back.
    private let retired = Mutex(false)

    /// One file per Mac in `folder`, named from a hash of `host`. `relay`
    /// makes a client for a mailbox. Use `shared` in the app, so only one
    /// store ever writes a file.
    public init(folder: URL, host: String, relay: @escaping @Sendable (String) -> QueueRelay) {
        file = Self.file(folder: folder, host: host)
        self.relay = relay
        let saved = Self.load(file)
        copies = saved?.copies ?? []
        deleting = saved?.deleting ?? []
    }

    private static func file(folder: URL, host: String) -> URL {
        folder.appendingPathComponent(NotificationSeal.opaque(host) + ".json")
    }

    /// Nil when there's no file yet. A file that's there but can't be read
    /// is moved aside first, so starting empty doesn't save over it.
    private static func load(_ file: URL) -> Saved? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        if let data = try? Data(contentsOf: file), let saved = try? CompanionCoding.decoder.decode(Saved.self, from: data) {
            return saved
        }
        let name = file.deletingPathExtension().lastPathComponent
        let aside = file.deletingLastPathComponent()
            .appendingPathComponent("\(name).unreadable-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.moveItem(at: file, to: aside)
        return nil
    }

    private static let stores = Mutex<[URL: QueueStoreCore]>([:])

    /// The one store for this Mac's file, made the first time it's asked
    /// for. Two stores on one file would overwrite each other's saves.
    public static func shared(folder: URL, host: String, relay: @escaping @Sendable (String) -> QueueRelay) -> QueueStoreCore {
        let file = file(folder: folder, host: host)
        return stores.withLock { stores in
            if let store = stores[file] { return store }
            let store = QueueStoreCore(folder: folder, host: host, relay: relay)
            stores[file] = store
            return store
        }
    }

    /// Drops this Mac's file and its store, for when the Mac is unpaired.
    public static func forget(folder: URL, host: String) {
        let file = file(folder: folder, host: host)
        stores.withLock { stores in stores[file] = nil }
        try? FileManager.default.removeItem(at: file)
    }

    /// For a Mac that's now at a different host: its queued prompts go
    /// with it, replacing anything the new host had. Both hosts' stores
    /// leave the table, and the old one stops saving, so the next `shared`
    /// for the new host reads the moved file.
    public static func move(folder: URL, from old: String, to new: String) {
        guard old != new else { return }
        let from = file(folder: folder, host: old)
        let to = file(folder: folder, host: new)
        stores.withLock { stores in
            stores[from]?.retired.withLock { $0 = true }
            stores[to]?.retired.withLock { $0 = true }
            stores[from] = nil
            stores[to] = nil
        }
        guard FileManager.default.fileExists(atPath: from.path) else { return }
        try? FileManager.default.removeItem(at: to)
        try? FileManager.default.moveItem(at: from, to: to)
    }

    /// Application Support/Queued.
    public static var standardFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Queued", isDirectory: true)
    }

    /// Oldest first. Nil means every project.
    public func items(projectID: UUID?) -> [LocalQueued] {
        copies.filter { projectID == nil || $0.prompt.projectID == projectID }
            .sorted { $0.prompt.queuedAt < $1.prompt.queuedAt }
    }

    /// Saves the prompt here first, so it isn't lost if sending fails.
    /// A prompt the relay can never take (too long, or a full mailbox)
    /// isn't kept, so the text can be changed and tried again.
    public func queue(_ prompt: QueuedPrompt, token: String) async -> QueueRelayError? {
        let mailbox = QueueSeal.mailboxID(token: token)
        copies.append(LocalQueued(prompt: prompt, mailbox: mailbox, status: .unsent))
        save()
        let error = await send(prompt.id, token: token)
        if error == .tooLarge || error == .full {
            remove(prompt.id)
        }
        return error
    }

    /// Changes the text, keeping the id, so the relay replaces it. Returns
    /// `.taken` when the Mac already started it, and drops the copy.
    public func edit(_ id: UUID, text: String, token: String) async -> QueueRelayError? {
        guard let index = copies.firstIndex(where: { $0.id == id }) else { return nil }
        let before = copies[index]
        copies[index].prompt.prompt = text
        save()
        let error = await send(id, token: token)
        // Not sent and not kept to send later: the old text stands.
        let stillOld = error == .unreachable && copies.first(where: { $0.id == id })?.mailbox == before.mailbox
            && before.mailbox != QueueSeal.mailboxID(token: token)
        if error == .tooLarge || error == .full || stillOld, let index = copies.firstIndex(where: { $0.id == id }) {
            copies[index] = before
            save()
        }
        return error
    }

    /// Sends an expired prompt again, as if just queued.
    public func queueAgain(_ id: UUID, token: String) async -> QueueRelayError? {
        guard let index = copies.firstIndex(where: { $0.id == id }) else { return nil }
        copies[index].prompt.queuedAt = Date()
        copies[index].status = .unsent
        save()
        return await send(id, token: token)
    }

    /// Takes it off the relay too, when it might be there. If the relay
    /// can't be reached, the delete is kept and tried again on refresh.
    public func delete(_ id: UUID, token: String) async {
        guard let copy = copies.first(where: { $0.id == id }) else { return }
        copies.removeAll { $0.id == id }
        if copy.status != .expired {
            deleting.append(Deleting(id: id, mailbox: copy.mailbox))
        }
        save()
        if copy.status != .expired {
            await finishDelete(Deleting(id: id, mailbox: copy.mailbox))
        }
    }

    /// Sends what hasn't gone out, then asks the relay what happened to
    /// the rest. A copy left on an old mailbox (from before a new pairing
    /// code) that the Mac never took moves to the current one.
    ///
    /// Only waiting copies are asked about: expired ones stay as they are
    /// until queued again. Copies can change while a list is out (an edit
    /// that fails makes one unsent), so each is looked at again after.
    public func refresh(token: String) async {
        let current = QueueSeal.mailboxID(token: token)

        for pending in deleting {
            await finishDelete(pending)
        }

        for copy in copies where copy.status == .unsent {
            _ = await send(copy.id, token: token)
        }

        let mailboxes = Set(copies.filter { $0.status == .waiting }.map(\.mailbox))
        for mailbox in mailboxes.sorted() {
            let ids = copies.filter { $0.mailbox == mailbox && $0.status == .waiting }.map(\.id)
            for start in stride(from: 0, to: ids.count, by: Self.maxListed) {
                let batch = Array(ids[start..<min(start + Self.maxListed, ids.count)])
                guard let listing = try? await relay(mailbox).list(asking: batch) else { continue }
                for id in batch {
                    // Moved or deleted while the list was out: this answer
                    // isn't about it anymore.
                    guard let copy = copies.first(where: { $0.id == id }), copy.mailbox == mailbox else { continue }
                    let state = QueueSync.state(of: id, items: listing.items, taken: listing.taken)
                    if state == .started {
                        remove(id)
                        continue
                    }
                    // An edit that failed is sent again next time, not
                    // overwritten by what the relay held before it.
                    guard copy.status != .unsent else { continue }
                    if mailbox != current {
                        // From before a new pairing code, and not taken:
                        // send it to the new mailbox. send() asks the old
                        // one again and takes it off there first.
                        _ = await send(id, token: token)
                    } else {
                        setStatus(id, state == .waiting ? .waiting : .expired)
                    }
                }
            }
        }
    }

    // MARK: Helpers

    /// Seals the copy for the current mailbox and adds it.
    ///
    /// A copy on another mailbox (from before a new pairing code) may be
    /// waiting there or already taken, so that mailbox is asked first:
    /// taken there means it started, and it's dropped. If it can't be
    /// asked, the copy stays where it is for the next refresh.
    private func send(_ id: UUID, token: String) async -> QueueRelayError? {
        guard let copy = copies.first(where: { $0.id == id }) else { return nil }
        let mailbox = QueueSeal.mailboxID(token: token)
        guard let sealed = try? QueueSeal.seal(copy.prompt, key: QueueSeal.key(token: token), mailbox: mailbox) else {
            return .tooLarge
        }
        guard sealed.count <= Self.maxSealed else { return .tooLarge }
        if copy.mailbox != mailbox {
            let old = relay(copy.mailbox)
            guard let listing = try? await old.list(asking: [id]) else { return .unreachable }
            if listing.taken.contains(id) {
                remove(id)
                return .taken
            }
            if listing.items.contains(where: { $0.id == id }) {
                do { try await old.delete(id: id) } catch { return .unreachable }
            }
            // Deleted while asking.
            guard copies.contains(where: { $0.id == id }) else { return nil }
        }
        update(id) { $0.mailbox = mailbox }
        do {
            try await relay(mailbox).add(id: id, sealed: sealed)
            if copies.contains(where: { $0.id == id }) {
                setStatus(id, .waiting)
            } else {
                // Deleted while the add was on its way: take it back off.
                let pending = Deleting(id: id, mailbox: mailbox)
                if !deleting.contains(pending) {
                    deleting.append(pending)
                    save()
                }
                await finishDelete(pending)
            }
            return nil
        } catch let error as QueueRelayError {
            if error == .taken {
                remove(id)
            } else {
                setStatus(id, .unsent)
            }
            return error
        } catch {
            setStatus(id, .unsent)
            return .unreachable
        }
    }

    private func finishDelete(_ pending: Deleting) async {
        guard (try? await relay(pending.mailbox).delete(id: pending.id)) != nil else { return }
        deleting.removeAll { $0 == pending }
        save()
    }

    private func update(_ id: UUID, _ change: (inout LocalQueued) -> Void) {
        guard let index = copies.firstIndex(where: { $0.id == id }) else { return }
        change(&copies[index])
        save()
    }

    private func setStatus(_ id: UUID, _ status: LocalQueued.Status) {
        update(id) { $0.status = status }
    }

    private func remove(_ id: UUID) {
        copies.removeAll { $0.id == id }
        save()
    }

    private func save() {
        guard !retired.withLock({ $0 }) else { return }
        let folder = file.deletingLastPathComponent()
        guard let data = try? CompanionCoding.encoder.encode(Saved(copies: copies, deleting: deleting)) else { return }
        LocalFolder.make(folder)
        try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
