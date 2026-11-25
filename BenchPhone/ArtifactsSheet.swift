import BenchKit
import SwiftUI

/// The pages Claude published for a project, newest first, in a sheet.
struct ArtifactsSheet: View {
    let links: [ArtifactLink]?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ArtifactsList(links: links)
                .navigationTitle("Artifacts")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
    }
}

/// The pages themselves, for the sheet and the iPad's inspector. Tapping
/// one opens it in the Claude app if it's installed, or Safari.
struct ArtifactsList: View {
    let links: [ArtifactLink]?
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            if let links {
                if links.isEmpty {
                    EmptyStateScaffold(title: "No Artifacts Yet",
                                       message: "Pages Claude publishes for this project, like dashboards and mockups, show up here.") {
                        ArtifactsEmptyIllustration(appeared: $0)
                    }
                } else {
                    List {
                        let today = links.filter { Calendar.current.isDateInToday($0.updated) }
                        let earlier = links.filter { !Calendar.current.isDateInToday($0.updated) }
                        if !today.isEmpty { Section("Today") { ForEach(today, content: row) } }
                        if !earlier.isEmpty { Section("Earlier") { ForEach(earlier, content: row) } }
                    }
                    .scrollContentBackground(.hidden)
                }
            } else {
                LoadingState()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PhoneTheme.canvas)
    }

    private func row(_ link: ArtifactLink) -> some View {
        Button {
            if let url = URL(string: link.url) { openURL(url) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: link.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(PhoneTheme.accent)
                    .frame(width: 34, height: 34)
                    .background(PhoneTheme.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(link.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(PhoneTheme.ink)
                        .lineLimit(2)
                    Text(when(link))
                        .font(.footnote)
                        .foregroundStyle(PhoneTheme.inkMuted)
                    if let session = link.sessionTitle {
                        Text("From “\(session)”")
                            .font(.caption)
                            .foregroundStyle(PhoneTheme.inkMuted.opacity(0.8))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(PhoneTheme.inkMuted)
                    .padding(.top, 4)
            }
        }
        .listRowBackground(PhoneTheme.surface)
        .contextMenu {
            Button("Copy Link", systemImage: "doc.on.doc") { UIPasteboard.general.string = link.url }
            if let url = URL(string: link.url) { ShareLink(item: url) }
        }
    }

    private func when(_ link: ArtifactLink) -> String {
        let time = Calendar.current.isDateInToday(link.updated)
            ? link.updated.formatted(.relative(presentation: .named))
            : link.updated.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        if let version = link.version, version > 1 { return "\(time) · version \(version)" }
        return time
    }
}
