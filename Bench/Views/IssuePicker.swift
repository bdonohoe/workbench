import BenchKit
import SwiftUI

/// A repo's open GitHub issues, to start an agent from. Picking one fills
/// in the New Agent sheet's prompt and branch.
struct IssuePicker: View {
    let issues: [GitHubIssue]
    let selected: GitHubIssue?
    let pick: (GitHubIssue) -> Void

    @State private var search = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Open Issues")
                    .font(.ui(size: 13, weight: .semibold))
                TextField("Search by title, number or label", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .font(.ui(size: 12))
                    .focused($searchFocused)
                    .onSubmit { if let first = filtered.first { pick(first) } }
            }
            .padding(12)
            Divider()
            if filtered.isEmpty {
                Text("Nothing matches “\(search)”.")
                    .font(.ui(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filtered) { issue in
                            IssueRow(issue: issue, isSelected: issue.number == selected?.number) { pick(issue) }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: 420)
        .task { searchFocused = true }
    }

    private var filtered: [GitHubIssue] {
        issues.filter { $0.matches(search) }
    }
}

private struct IssueRow: View {
    let issue: GitHubIssue
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "#\(issue.number)")
                    .font(.ui(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(issue.title)
                        .font(.ui(size: 13, weight: .medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.ui(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.ui(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.07 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(Text(verbatim: "Issue \(issue.number), \(issue.title)"))
    }

    /// "bug, sidebar · 2 days ago"
    private var detail: String {
        var parts: [String] = []
        if !issue.labels.isEmpty { parts.append(issue.labels.joined(separator: ", ")) }
        if let updated = issue.updated {
            parts.append(updated.formatted(.relative(presentation: .named)))
        }
        return parts.joined(separator: " · ")
    }
}
