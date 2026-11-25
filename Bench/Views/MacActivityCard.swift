import BenchKit
import SwiftUI

/// The colors the Mac's meters and card share: grey while things are
/// fine, then the usage scale's yellow and orange.
enum MeterColor {
    static let warm = UsageColor.color(for: 60)
    static let hot = UsageColor.color(for: 100)

    static func cpu(_ summary: MacActivity.Summary, calm: Color) -> Color {
        summary.cpu >= 90 ? hot : summary.cpu >= 65 ? warm : calm
    }

    static func memory(_ summary: MacActivity.Summary, calm: Color) -> Color {
        switch summary.pressure {
        case .critical: hot
        case .warning: warm
        case .normal: calm
        }
    }

    static func level(_ level: MacActivity.Pressure) -> Color {
        switch level {
        case .critical: hot
        case .warning: warm
        case .normal: UsageColor.color(for: 0)
        }
    }

    static func headline(_ summary: MacActivity.Summary) -> String {
        if summary.thermal == .serious || summary.thermal == .critical { return "Your Mac is slowing down to stay cool" }
        if summary.pressure == .critical { return "Your Mac is running out of memory" }
        if summary.pressure == .warning { return "Memory is getting tight" }
        switch summary.level {
        case .critical: return "Your Mac is working flat out"
        case .warning: return "Your Mac is busy"
        case .normal: return "Your Mac is doing fine"
        }
    }
}

/// Which projects are using the Mac, measured only while this is open.
/// Part of the card at the foot of the sidebar, which sets the padding.
struct MacActivityCard: View {
    @Environment(AppStore.self) private var store
    @Environment(ProjectIcons.self) private var icons

    private var activity: MacActivity { .shared }

    /// Programs carrying the ID of a tab that's been closed.
    private static let leftRunningID = "closed"

    private struct Line: Identifiable {
        var id: String
        var name: String
        var project: Project?
        var share: MacActivity.Share
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let summary = activity.summary {
                VStack(alignment: .leading, spacing: 3) {
                    Text(MeterColor.headline(summary))
                        .font(.headline)
                        .foregroundStyle(summary.level == .normal ? Color.primary : MeterColor.level(summary.level))
                    Text("\(summary.cpu)% of \(summary.cores) cores · \(gigabytes(summary.memoryUsed)) of \(gigabytes(summary.memoryTotal, digits: 0)) memory")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let note = note(summary) {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                }
            }
            Divider()
            if let breakdown = activity.breakdown {
                table(breakdown)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Measuring…").foregroundStyle(.secondary)
                }
                .font(.callout)
                .frame(maxWidth: .infinity, minHeight: 60)
            }
            if activity.breakdown.map({ projectLines($0).contains { $0.id == Self.leftRunningID } }) == true {
                Text("Left running: programs started in tabs you've since closed. They keep using memory until you quit them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Updated every 10 seconds while this is open, busiest memory first. CPU is in cores: 1.0 is one core fully busy.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func table(_ breakdown: MacActivity.Breakdown) -> some View {
        let lines = projectLines(breakdown)
        return Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
            GridRow {
                Text("Project").gridCellColumns(2)
                Text("CPU").gridColumnAlignment(.trailing)
                Text("Memory").gridColumnAlignment(.trailing)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if lines.isEmpty {
                GridRow {
                    Text("Nothing running in your projects.")
                        .foregroundStyle(.secondary)
                        .gridCellColumns(4)
                }
                .font(.callout)
            }
            ForEach(lines) { line in
                row(icon: line.project.map { AnyView(ProjectIcon(project: $0, image: icons.image(for: $0), size: 16)) }
                        ?? AnyView(Image(systemName: "xmark.square").font(.ui(size: 10)).foregroundStyle(.secondary)),
                    name: line.name, share: line.share, hasCPU: breakdown.hasCPU, emphasized: true)
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            row(icon: AnyView(Image(systemName: "hammer").font(.ui(size: 10)).foregroundStyle(.secondary).frame(width: 16)),
                name: "Workbench", share: breakdown.workbench, hasCPU: breakdown.hasCPU, emphasized: false)
            row(icon: AnyView(Image(systemName: "square.grid.2x2").font(.ui(size: 10)).foregroundStyle(.secondary).frame(width: 16)),
                name: "Other apps", share: breakdown.other, hasCPU: breakdown.hasCPU, emphasized: false)
        }
        .font(.callout)
    }

    private func row(icon: AnyView, name: String, share: MacActivity.Share, hasCPU: Bool, emphasized: Bool) -> some View {
        GridRow {
            icon.frame(width: 16, height: 16)
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(emphasized ? .primary : .secondary)
            Text(hasCPU ? String(format: "%.1f", share.cores) : "–")
                .monospacedDigit()
                .foregroundStyle(emphasized && share.cores >= 1 ? .primary : .secondary)
            Text(gigabytes(share.memory))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    /// Each project with its worktrees folded in, most memory first (CPU
    /// swings too much to sort by without rows jumping around), leaving
    /// out ones barely doing anything.
    private func projectLines(_ breakdown: MacActivity.Breakdown) -> [Line] {
        var tabToProject: [UUID: UUID] = [:]
        for project in store.projects {
            for tab in project.tabs { tabToProject[tab.id] = store.rootID(of: project.id) }
        }
        var byProject: [UUID: MacActivity.Share] = [:]
        var orphan = MacActivity.Share()
        for (tab, share) in breakdown.tabs {
            if let project = tabToProject[tab] {
                byProject[project, default: .init()].cores += share.cores
                byProject[project, default: .init()].memory += share.memory
            } else {
                orphan.cores += share.cores
                orphan.memory += share.memory
            }
        }
        var lines = byProject.compactMap { id, share -> Line? in
            guard let project = store.project(id) else { return nil }
            guard share.cores >= 0.05 || share.memory >= 50_000_000 else { return nil }
            return Line(id: id.uuidString, name: project.name, project: project, share: share)
        }
        if orphan.cores >= 0.05 || orphan.memory >= 50_000_000 {
            lines.append(Line(id: Self.leftRunningID, name: "Left running", project: nil, share: orphan))
        }
        return lines
            .sorted { $0.share.memory > $1.share.memory }
            .prefix(6).map { $0 }
    }

    private func note(_ summary: MacActivity.Summary) -> String? {
        if summary.thermal == .serious || summary.thermal == .critical {
            return "Builds and tests will run slower until it cools off."
        }
        switch summary.pressure {
        case .critical: return "macOS is compressing memory and swapping to disk, which slows everything down."
        case .warning: return "macOS has started compressing memory to make room."
        case .normal: return nil
        }
    }

    private func gigabytes(_ bytes: UInt64, digits: Int = 1) -> String {
        MacActivity.gigabytes(bytes, digits: digits)
    }
}

extension MacActivity {
    /// "16.1 GB", "24 GB" with no digits, "512 MB" under a gigabyte.
    static func gigabytes(_ bytes: UInt64, digits: Int = 1) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb < 1, digits > 0 { return "\(Int((Double(bytes) / 1_048_576).rounded())) MB" }
        return String(format: "%.\(digits)f GB", gb)
    }
}
