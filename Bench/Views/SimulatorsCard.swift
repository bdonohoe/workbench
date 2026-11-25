import BenchKit
import SwiftUI

extension Simulator.Age {
    /// Green while it's new, then yellow, orange and red the longer it's
    /// been left on.
    var color: Color {
        switch self {
        case .fresh: Color(nsColor: .systemGreen)
        case .lingering: Color(nsColor: .systemYellow)
        case .forgotten: Color(nsColor: .systemOrange)
        case .neglected: Color(nsColor: .systemRed)
        }
    }
}

/// The simulators that are running, each with how long it's been on, what
/// it holds in memory, and a way to shut it down. Part of the card at the
/// foot of the sidebar, which sets the padding.
struct SimulatorsCard: View {
    private var watch: SimulatorWatch { .shared }

    var body: some View {
        let simulators = watch.simulators
        // Running times tick by the minute.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = SimulatorWatch.clock(context.date)
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(simulators.count == 1 ? "1 simulator running" : "\(simulators.count) simulators running")
                            .font(.headline)
                        if let summary = summary(simulators, now: now) {
                            Text(summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    if simulators.count > 1 {
                        Button("Shut Down All") { watch.shutDownAll() }
                            .controlSize(.small)
                            .disabled(simulators.allSatisfy { watch.shuttingDown.contains($0.id) })
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(simulators) { simulator in
                        row(simulator, now: now)
                    }
                }
            }
        }
    }

    private func row(_ simulator: Simulator, now: Date) -> some View {
        let age = simulator.age(at: now)
        let stopping = watch.shuttingDown.contains(simulator.id)
        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: simulator.kind.symbol)
                .font(.ui(size: 15))
                .foregroundStyle(age.color)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(simulator.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(details(simulator, now: now))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let origin = simulator.origin {
                    Text(origin)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if stopping {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Shutting down \(simulator.name)")
            } else {
                Button("Shut Down") { watch.shutDown(simulator) }
                    .controlSize(.small)
                    .accessibilityLabel("Shut down \(simulator.name)")
            }
        }
        .opacity(stopping ? 0.6 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityValue(age.spoken)
    }

    /// "iOS 27.2 · 2h 5m · 2.1 GB", leaving out what isn't known.
    private func details(_ simulator: Simulator, now: Date) -> String {
        var parts: [String] = []
        if !simulator.runtime.isEmpty { parts.append(simulator.runtime) }
        parts.append(simulator.runningFor(at: now))
        if let bytes = watch.memory[simulator.id], bytes > 0 { parts.append(MacActivity.gigabytes(bytes)) }
        return parts.joined(separator: " · ")
    }

    /// What they add up to, once memory has been measured.
    private func summary(_ simulators: [Simulator], now: Date) -> String? {
        let total = simulators.reduce(UInt64(0)) { $0 + (watch.memory[$1.id] ?? 0) }
        guard total > 0 else { return nil }
        return "Holding \(MacActivity.gigabytes(total)) of memory"
    }
}
