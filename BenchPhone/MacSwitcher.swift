import BenchKit
import SwiftUI
import Synchronization

/// Which paired Macs can be reached right now. The connected one is
/// answered by the client; the others get a quick knock on their door.
@Observable
final class MacReachability {
    enum State: Equatable {
        case checking
        /// Bench answered, over Tailscale or the home network.
        case bench
        /// Tailscale answered, but nothing is behind it: Bench isn't open there.
        case macOnly
        case offline
    }

    private(set) var states: [String: State] = [:]

    func check(_ macs: [PairingInfo]) {
        for mac in macs {
            states[mac.host] = .checking
            Task { [weak self] in
                let state = await Self.probe(mac)
                self?.states[mac.host] = state
            }
        }
    }

    /// Knocks over Tailscale first, as the client does. If that doesn't
    /// reach Bench and the Mac offers the home network, looks for it there
    /// and knocks again, trusting only the Mac's own certificate.
    private static func probe(_ mac: PairingInfo) async -> State {
        var state = State.offline
        if let url = mac.socketURL {
            state = await ping(URLSession.shared.webSocketTask(with: url))
            if state == .bench { return state }
        }
        guard let local = mac.local,
              let url = try? await LocalResolver.resolve(mac: local.mac, timeout: 3) else { return state }
        let session = PinnedSession.make(pin: local.fingerprint)
        defer { session.finishTasksAndInvalidate() }
        // Found on the home network means Bench is up: it's Bench that
        // advertises the service.
        return await ping(session.webSocketTask(with: url)) == .bench ? .bench : state
    }

    /// Opens a WebSocket to the Mac and pings it. Bench's server only speaks
    /// WebSocket, so plain HTTP can't tell "Bench is up" from "nothing is
    /// there": Tailscale Serve answers 502 to both.
    private static func ping(_ task: URLSessionWebSocketTask) async -> State {
        task.resume()
        let slot = Mutex<CheckedContinuation<State, Never>?>(nil)
        let finish: @Sendable (State) -> Void = { state in
            slot.withLock { continuation in
                continuation?.resume(returning: state)
                continuation = nil
            }
        }
        let state = await withCheckedContinuation { (continuation: CheckedContinuation<State, Never>) in
            slot.withLock { $0 = continuation }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { finish(.offline) }
            task.sendPing { error in
                guard let error = error as NSError? else { return finish(.bench) }
                // Serve answered, but had nothing to hand the connection to.
                finish(error.code == NSURLErrorBadServerResponse ? .macOnly : .offline)
            }
        }
        task.cancel(with: .normalClosure, reason: nil)
        return state
    }
}

/// One tap to flip between Macs, shown only when there's more than one.
struct MacChips: View {
    @Environment(PairingStore.self) private var pairing
    @Environment(CompanionClient.self) private var client
    let reachability: MacReachability

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pairing.macs, id: \.host) { mac in
                    let selected = mac.host == pairing.info?.host
                    Button {
                        pairing.select(host: mac.host)
                    } label: {
                        HStack(spacing: 7) {
                            Circle()
                                .fill(dot(for: mac.host, selected: selected))
                                .frame(width: 7, height: 7)
                            Text(pairing.name(for: mac.host))
                                .font(.subheadline.weight(selected ? .semibold : .medium))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .foregroundStyle(selected ? PhoneTheme.canvas : PhoneTheme.ink)
                        .background(selected ? PhoneTheme.ink : PhoneTheme.surface, in: Capsule())
                        .overlay(Capsule().strokeBorder(selected ? .clear : PhoneTheme.hairline))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(pairing.name(for: mac.host)), \(describe(mac.host, selected: selected))")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .contextMenu {
                        Button("Move Left", systemImage: "arrow.left") { pairing.move(host: mac.host, by: -1) }
                            .disabled(mac.host == pairing.macs.first?.host)
                        Button("Move Right", systemImage: "arrow.right") { pairing.move(host: mac.host, by: 1) }
                            .disabled(mac.host == pairing.macs.last?.host)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 2)
            .padding(.bottom, 6)
        }
        .padding(.horizontal, -16)
        .animation(.snappy, value: pairing.info?.host)
    }

    private func dot(for host: String, selected: Bool) -> Color {
        if selected {
            switch client.status {
            case .connected: return PhoneTheme.done
            case .connecting: return PhoneTheme.waiting
            case .disconnected: return PhoneTheme.inkMuted.opacity(0.6)
            }
        }
        switch reachability.states[host] {
        case .bench: return PhoneTheme.done
        case .macOnly: return PhoneTheme.waiting
        case .offline: return PhoneTheme.inkMuted.opacity(0.5)
        case .checking, nil: return PhoneTheme.inkMuted.opacity(0.25)
        }
    }

    private func describe(_ host: String, selected: Bool) -> String {
        if selected {
            switch client.status {
            case .connected: return "connected"
            case .connecting: return "connecting"
            case .disconnected: return "not connected"
            }
        }
        switch reachability.states[host] {
        case .bench: return "available"
        case .macOnly: return "online, Workbench not open"
        case .offline: return "offline"
        case .checking, nil: return "checking"
        }
    }
}
