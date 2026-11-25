import SwiftUI

extension EnvironmentValues {
    /// The session's subagents, by the Agent call that started each.
    @Entry public var agentStatuses: [String: AgentStatus] = [:]
}

public extension CompanionSession {
    /// Its subagents, by the Agent call that started each, for `agentStatuses`.
    var agentsByCall: [String: AgentStatus] {
        Dictionary((agents ?? []).map { ($0.toolUseID, $0) }, uniquingKeysWith: { _, new in new })
    }
}

extension TranscriptMessage {
    /// True for a call that starts a subagent.
    var startsAgent: Bool { agent != nil || tool == .agent }
}

/// Subagents Claude started together, one line each: what it's for, and
/// what it's doing now or how it went.
struct AgentCard: View {
    @Environment(\.companionPalette) private var palette
    @Environment(\.stepFonts) private var fonts
    @Environment(\.agentStatuses) private var statuses
    let calls: [TranscriptMessage]
    let results: [String: TranscriptMessage]
    /// True while Claude is still on this run.
    let isLive: Bool

    var body: some View {
        let rows = calls.map(row)
        VStack(alignment: .leading, spacing: 0) {
            if rows.count > 1 {
                let running = rows.filter { $0.state == .running }.count
                HStack(spacing: 6) {
                    Image(systemName: "person.2")
                    Text(running > 0 ? "\(rows.count) agents, \(running) working" : "\(rows.count) agents")
                }
                .font(fonts.text.weight(.semibold))
                .foregroundStyle(palette.inkMuted)
                .padding(.horizontal, 12)
                .padding(.top, 9)
                .padding(.bottom, 2)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                AgentRowView(row: row, single: rows.count == 1)
                    .overlay(alignment: .top) {
                        if index > 0 { Rectangle().fill(palette.hairline).frame(height: 1).padding(.leading, 12) }
                    }
            }
        }
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(palette.hairline))
        .animation(.snappy(duration: 0.25), value: rows.map(\.state))
    }

    struct Row: Identifiable {
        enum State: Equatable { case running, done, failed, stopped, unknown }
        let id: String
        let title: String
        let type: String?
        let state: State
        /// Its current step while running, or how it went.
        let note: String?
        let started: Date?
    }

    private func row(_ call: TranscriptMessage) -> Row {
        let status = call.toolUseID.flatMap { statuses[$0] }
        let result = call.toolUseID.flatMap { results[$0] }
        // A background agent's call returns right away with a note that
        // it started; that isn't the agent finishing.
        let launched = result?.text.hasPrefix("Async agent launched") == true
        let type = (status?.type ?? call.agent?.type).flatMap { $0 == "general-purpose" ? nil : $0 }
        let title = status?.description ?? call.agent?.description ?? "Subagent"
        let state: Row.State
        if result?.isError == true || result?.wasDeclined == true {
            state = result?.wasDeclined == true ? .stopped : .failed
        } else if let status {
            state = status.isFinished ? .done : status.isRunning ? .running : .stopped
        } else if result != nil, !launched {
            state = .done
        } else {
            state = isLive ? .running : .unknown
        }
        var note: String?
        switch state {
        case .running:
            note = status?.action ?? "Starting"
        case .done:
            var parts: [String] = []
            if let steps = status?.steps, steps > 0 { parts.append(steps == 1 ? "1 step" : "\(steps) steps") }
            if let start = status?.startedAt ?? call.at, let end = status?.finishedAt ?? result?.at, end > start {
                parts.append(Self.duration(end.timeIntervalSince(start)))
            }
            note = parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .failed: note = "Failed"
        case .stopped: note = "Stopped"
        case .unknown: note = nil
        }
        return Row(id: call.id, title: title, type: type, state: state, note: note, started: status?.startedAt ?? call.at)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        return s < 60 ? "\(s)s" : s < 3600 ? "\(s / 60)m \(s % 60)s" : "\(s / 3600)h \(s % 3600 / 60)m"
    }
}

private struct AgentRowView: View {
    @Environment(\.companionPalette) private var palette
    @Environment(\.stepFonts) private var fonts
    let row: AgentCard.Row
    /// The only agent in its card, so it carries the icon itself.
    let single: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            mark.frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.title)
                        .foregroundStyle(palette.ink)
                        .lineLimit(2)
                    if let type = row.type {
                        Text(type)
                            .font(fonts.monoSmall)
                            .foregroundStyle(palette.inkMuted)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(palette.raised, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                }
                if let note = row.note {
                    HStack(spacing: 6) {
                        Text(note)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .contentTransition(.opacity)
                        if row.state == .running, let started = row.started {
                            Text(started, style: .timer)
                                .monospacedDigit()
                                .fixedSize()
                        }
                    }
                    .foregroundStyle(row.state == .failed ? StepColors.removed : palette.inkMuted)
                }
            }
            .font(fonts.text)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var mark: some View {
        switch row.state {
        case .running:
            ProgressView().controlSize(.mini)
        case .done:
            Image(systemName: "checkmark").foregroundStyle(StepColors.added)
                .font(.system(size: 11 * fonts.scale, weight: .semibold))
        case .failed:
            Image(systemName: "xmark").foregroundStyle(StepColors.removed)
                .font(.system(size: 11 * fonts.scale, weight: .semibold))
        case .stopped:
            Image(systemName: "stop.circle").foregroundStyle(palette.inkMuted)
                .font(.system(size: 11 * fonts.scale))
        case .unknown:
            Image(systemName: "person").foregroundStyle(palette.inkMuted)
                .font(.system(size: 11 * fonts.scale))
        }
    }
}

/// Claude Code's note that a background agent or command stopped: a quiet
/// line in the conversation, so you can see why Claude picked back up.
public struct TaskNoticeRow: View {
    @Environment(\.companionPalette) private var palette
    @Environment(\.stepFonts) private var fonts
    let message: TranscriptMessage

    public init(message: TranscriptMessage) {
        self.message = message
    }

    public var body: some View {
        let notice = message.notice
        HStack(spacing: 6) {
            Image(systemName: notice?.failed == true ? "xmark.circle" : notice?.stopped == true ? "stop.circle" : "checkmark.circle")
                .foregroundStyle(notice?.failed == true ? StepColors.removed : palette.inkMuted)
            Text(message.text)
                .foregroundStyle(palette.inkMuted)
                .lineLimit(2)
        }
        .font(fonts.text)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// After a long stretch of work: how long Claude worked and when it
/// finished, as its terminal prints after a run.
public struct TurnTimeRow: View {
    @Environment(\.companionPalette) private var palette
    @Environment(\.stepFonts) private var fonts
    let message: TranscriptMessage

    public init(message: TranscriptMessage) {
        self.message = message
    }

    private var line: String {
        guard let worked = message.worked else { return message.text }
        let duration = TurnTime.summary(id: message.id, worked: worked)
        guard let finished = message.at else { return duration }
        return duration + " · done " + TurnTime.finished(finished)
    }

    public var body: some View {
        Text(line)
            .font(fonts.text)
            .monospacedDigit()
            .foregroundStyle(palette.inkMuted)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

public extension Array where Element == AgentStatus {
    /// The agents worth pinning: ones still running, and ones that
    /// finished during the stretch of work under way (`activeSince`), so
    /// you can see them wrap up. Older ones live on in the conversation.
    func pinned(activeSince: Date?) -> [AgentStatus] {
        filter { agent in
            if agent.isRunning { return true }
            guard let since = activeSince, agent.isFinished, let finished = agent.finishedAt else { return false }
            return finished >= since
        }
    }

    /// How many are still running.
    var runningCount: Int { filter(\.isRunning).count }
}

public extension CompanionSession {
    /// Its agents worth pinning above the conversation, or nil for none.
    var pinnedAgents: [AgentStatus]? {
        let list = (agents ?? []).pinned(activeSince: since)
        return list.isEmpty ? nil : list
    }
}

/// Agents one per line, for the Mac's sidebar and the phone's agent bar:
/// what each is for, and what it's doing now or how it went.
public struct AgentStatusRows: View {
    @Environment(\.companionPalette) private var palette
    let agents: [AgentStatus]
    let textSize: CGFloat
    let spacing: CGFloat
    /// Colors from the environment's palette, or the system's.
    let usesPalette: Bool

    public init(agents: [AgentStatus], textSize: CGFloat = 12, spacing: CGFloat = 8, usesPalette: Bool = false) {
        self.agents = agents
        self.textSize = textSize
        self.spacing = spacing
        self.usesPalette = usesPalette
    }

    private var ink: Color { usesPalette ? palette.ink : .primary }
    private var muted: Color { usesPalette ? palette.inkMuted : .secondary }

    public var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(agents) { agent in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    mark(agent).frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(agent.description)
                            .foregroundStyle(agent.isRunning ? ink : muted)
                            .lineLimit(2)
                        HStack(spacing: 5) {
                            Text(note(agent))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .contentTransition(.opacity)
                            if agent.isRunning, let started = agent.startedAt {
                                Text(started, style: .timer).monospacedDigit().fixedSize()
                            }
                        }
                        .font(.system(size: textSize - 1))
                        .foregroundStyle(muted)
                    }
                }
                .font(.system(size: textSize))
                .accessibilityElement(children: .combine)
            }
        }
        .animation(.snappy(duration: 0.25), value: agents)
    }

    @ViewBuilder private func mark(_ agent: AgentStatus) -> some View {
        if agent.isRunning {
            ProgressView().controlSize(.mini)
        } else if agent.isFinished {
            Image(systemName: "checkmark").font(.system(size: textSize - 2, weight: .semibold)).foregroundStyle(StepColors.added)
        } else {
            Image(systemName: "stop.circle").font(.system(size: textSize - 2)).foregroundStyle(muted)
        }
    }

    private func note(_ agent: AgentStatus) -> String {
        if agent.isRunning { return agent.action ?? "Starting" }
        guard agent.isFinished else { return "Stopped" }
        var parts: [String] = []
        if agent.steps > 0 { parts.append(agent.steps == 1 ? "1 step" : "\(agent.steps) steps") }
        if let start = agent.startedAt, let end = agent.finishedAt, end > start { parts.append(AgentCard.duration(end.timeIntervalSince(start))) }
        return parts.isEmpty ? "Done" : "Done · " + parts.joined(separator: " · ")
    }
}
