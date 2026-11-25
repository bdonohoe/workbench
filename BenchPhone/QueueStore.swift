import BenchKit
import Foundation
import Observation
import UIKit

/// Prompts queued for the selected Mac while it's asleep. The work is in
/// `QueueStoreCore`; this keeps a copy of its list for the views and turns
/// relay errors into words.
@MainActor
@Observable
final class QueueStore {
    /// The selected Mac's queued prompts, oldest first.
    private(set) var items: [LocalQueued] = []
    /// False in a build with no relay to queue on.
    let isAvailable: Bool

    @ObservationIgnored private let url: URL?
    @ObservationIgnored private var core: QueueStoreCore?
    @ObservationIgnored private var pairing: PairingInfo?

    init() {
        url = QueueRelay.urlForBuild()
        isAvailable = url != nil
    }

    /// Points the store at the Mac the phone talks to now.
    func use(_ info: PairingInfo?) {
        guard info != pairing else { return }
        pairing = info
        items = []
        guard let info, let url else {
            core = nil
            return
        }
        // One store per Mac for the app's life, so a store left over from
        // before a switch can't save over this one's file.
        let core = QueueStoreCore.shared(folder: QueueStoreCore.standardFolder, host: info.host,
                                         relay: { QueueRelay(url: url, mailbox: $0) })
        self.core = core
        Task { await reload(core) }
    }

    func items(projectID: UUID) -> [LocalQueued] {
        items.filter { $0.prompt.projectID == projectID }
    }

    /// Returns what to tell the person when the relay said no. A prompt
    /// that couldn't be sent stays as "Not sent yet" with nothing to say.
    func queue(_ text: String, project: CompanionProject) async -> String? {
        guard let core, let token = pairing?.token else { return nil }
        let prompt = QueuedPrompt(projectID: project.id, projectName: project.name, prompt: text,
                                  device: UIDevice.current.name)
        let error = await core.queue(prompt, token: token)
        await reload(core)
        return Self.message(error)
    }

    func edit(_ id: UUID, text: String) async -> String? {
        guard let core, let token = pairing?.token else { return nil }
        let error = await core.edit(id, text: text, token: token)
        await reload(core)
        if error == .taken { return "Your Mac already started this one." }
        return Self.message(error)
    }

    func queueAgain(_ id: UUID) async -> String? {
        guard let core, let token = pairing?.token else { return nil }
        let error = await core.queueAgain(id, token: token)
        await reload(core)
        return Self.message(error)
    }

    func delete(_ id: UUID) async {
        guard let core, let token = pairing?.token else { return }
        // Off the screen right away, rather than after the relay answers.
        items.removeAll { $0.id == id }
        await core.delete(id, token: token)
        await reload(core)
    }

    /// Sends what hasn't gone out and checks on the rest.
    func refresh() async {
        guard let core, let token = pairing?.token else { return }
        await core.refresh(token: token)
        await reload(core)
    }

    private func reload(_ core: QueueStoreCore) async {
        let fresh = await core.items(projectID: nil)
        // A switch of Mac while waiting leaves this list alone.
        if core === self.core { items = fresh }
    }

    private static func message(_ error: QueueRelayError?) -> String? {
        switch error {
        case .tooLarge: "That's too long to queue. Try a shorter prompt."
        case .full: "Your Mac already has 25 prompts waiting."
        default: nil
        }
    }
}
