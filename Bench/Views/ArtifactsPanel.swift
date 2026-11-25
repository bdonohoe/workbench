import AppKit
import BenchKit
import SwiftUI

/// What the right sidebar shows below the checklist.
enum InspectorMode: String {
    case changes, files, artifacts
}

/// The switch at the top of the right sidebar. A folder without git has
/// no changes, so it only gets Files and Artifacts.
struct InspectorModePicker: View {
    @Binding var mode: InspectorMode
    var artifactCount: Int
    var hasChanges = true
    @Environment(\.inspectorPickerFit) private var fit

    var body: some View {
        Picker("Show", selection: $mode) {
            if hasChanges { label("Changes", symbol: "plusminus", count: 0).tag(InspectorMode.changes) }
            label("Files", symbol: "folder", count: 0).tag(InspectorMode.files)
            label("Artifacts", symbol: "doc.richtext", count: artifactCount).tag(InspectorMode.artifacts)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
    }

    @ViewBuilder private func label(_ title: String, symbol: String, count: Int) -> some View {
        switch fit {
        case .full: Text(count > 0 ? "\(title) \(count)" : title)
        case .noCounts: Text(title)
        case .icons: Image(systemName: symbol).accessibilityLabel(title).help(title)
        }
    }
}

/// How much the right panel's switch shows, from most to least room.
enum InspectorPickerFit { case full, noCounts, icons }

extension EnvironmentValues {
    @Entry var inspectorPickerFit = InspectorPickerFit.full
}

/// The right panel's part of the window's top band: its switch, then Send
/// Feedback and the button that hides the panel.
struct InspectorBand<Picker: View>: View {
    @ViewBuilder let picker: Picker

    var body: some View {
        WindowBand {
            // Send Feedback always stays, since the app is in beta and
            // feedback matters. A narrow panel shrinks the switch instead:
            // first it drops the Artifacts count, then it shows icons.
            ViewThatFits(in: .horizontal) {
                row(.full)
                row(.noCounts)
                row(.icons)
            }
        }
        .padding(.horizontal, 8)
    }

    private func row(_ fit: InspectorPickerFit) -> some View {
        HStack(spacing: 4) {
            picker.environment(\.inspectorPickerFit, fit)
            Spacer(minLength: 4)
            WindowTrailingButtons()
        }
    }
}

/// The pages Claude published for a project, newest first, split into
/// today and earlier. Click one to open it where you chose artifacts
/// should open; pointing at one offers both places by name.
struct ArtifactsPanel: View {
    let links: [ArtifactLink]?
    /// False for a project on another Mac, whose pages only open in the
    /// browser.
    var opensInTabs = true

    var body: some View {
        if let links {
            if links.isEmpty {
                EmptyStateScaffold(title: "No Artifacts Yet",
                                   message: "Pages Claude publishes for this project, like dashboards and mockups, show up here.",
                                   size: .compact) {
                    ArtifactsEmptyIllustration(appeared: $0)
                }
                .environment(\.companionPalette, TerminalTheme.shared.chatPalette)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        let today = links.filter { Calendar.current.isDateInToday($0.updated) }
                        let earlier = links.filter { !Calendar.current.isDateInToday($0.updated) }
                        if !today.isEmpty {
                            header("Today")
                            ForEach(today) { ArtifactRow(link: $0, opensInTabs: opensInTabs) }
                        }
                        if !earlier.isEmpty {
                            header("Earlier")
                            ForEach(earlier) { ArtifactRow(link: $0, opensInTabs: opensInTabs) }
                        }
                    }
                    .padding(.bottom, 10)
                }
            }
        } else {
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.ui(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            // In line with the rows' icons.
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 3)
    }
}

private struct ArtifactRow: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.companionPalette) private var palette
    @Environment(AppStore.self) private var store
    @AppStorage(ArtifactLinks.targetKey) private var target = ""
    let link: ArtifactLink
    let opensInTabs: Bool
    @State private var isHovering = false

    /// The tab this page is open in, in the project on screen.
    private var openTab: TabRecord? {
        guard opensInTabs, let url = URL(string: link.url) else { return nil }
        return store.selectedProject?.tabs.first { $0.kind == .preview && ($0.pageURL ?? $0.previewURL) == url }
    }

    /// Where a click on the row goes, in words.
    private var clickHelp: String {
        if openTab != nil { return "Go to this page's tab" }
        guard opensInTabs else { return "Open in your browser" }
        switch ArtifactLinkTarget(rawValue: target) {
        case .workbench: return "Open in a Workbench tab"
        case .browser: return "Open in your browser"
        case nil: return "Open this page. The first time, Workbench asks where"
        }
    }

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: link.symbol)
                    .font(.ui(size: 12, weight: .semibold))
                    .foregroundStyle(palette.accent)
                    .frame(width: 28, height: 28)
                    .background(palette.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(link.title)
                        .font(.ui(size: Theme.TypeScale.ui, weight: .semibold))
                        .lineLimit(1)
                    // The actions take the date's line, across the row's
                    // whole width so they can tell how much room there is.
                    ZStack(alignment: .leading) {
                        Text(when)
                            .font(.ui(size: Theme.TypeScale.meta))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .opacity(isHovering ? 0 : 1)
                        if isHovering { actions }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let session = link.sessionTitle {
                        Text("From “\(session)”")
                            .font(.ui(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            // Room inside the fill on every side. The row style adds the
            // inset outside it, the same as the Changes and Files rows.
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            // The page that's open in a tab here is marked, like the file
            // a diff tab is showing.
            .inspectorRow(isSelected: openTab != nil, isHovering: isHovering)
        }
        .buttonStyle(.pressable)
        .onHover { isHovering = $0 }
        .help(clickHelp)
        .contextMenu {
            if opensInTabs { Button("Open in Workbench Tab", action: openInTab) }
            Button("Open in Browser", action: openInBrowser)
            Button("Copy Link", action: copy)
        }
    }

    /// Each place the page can go, by name, so a click is never a guess.
    /// A narrower panel gets shorter names.
    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            actionRow(tab: "Open in Tab", browser: "Open in Browser", copy: "Copy Link")
            actionRow(tab: "Open in Tab", browser: "Browser", copy: "Copy Link")
            // The panel at its narrowest still says "Open in".
            actionRow(tab: "Open in Tab", browser: "Browser", copy: "Copy")
        }
        .buttonStyle(.borderless)
        .font(.ui(size: 11, weight: .medium))
        .foregroundStyle(palette.accent)
    }

    private func actionRow(tab: String, browser: String, copy copyTitle: String) -> some View {
        HStack(spacing: 5) {
            if opensInTabs {
                Button(openTab != nil ? "Go to Tab" : tab, action: openInTab)
                    .help(openTab != nil ? "Go to this page's tab" : "Open in a Workbench tab")
                separator
            }
            Button(browser, action: openInBrowser)
                .help("Open in your browser")
            separator
            Button(copyTitle, action: copy)
                .help("Copy this page's link")
        }
        .lineLimit(1)
        .fixedSize()
    }

    private var separator: some View {
        Text("·").foregroundStyle(.tertiary)
    }

    private var when: String {
        let time = Calendar.current.isDateInToday(link.updated)
            ? link.updated.formatted(.relative(presentation: .named))
            : link.updated.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        if let version = link.version, version > 1 { return "\(time) · version \(version)" }
        return time
    }

    /// The row itself: the page's tab if it has one, or else wherever you
    /// chose artifacts should open.
    private func open() {
        if openTab != nil {
            openInTab()
        } else if let url = URL(string: link.url) {
            openURL(url)
        }
    }

    private func openInTab() {
        if let url = URL(string: link.url) { ArtifactLinks.openInWorkbench(url) }
    }

    private func openInBrowser() {
        if let url = URL(string: link.url) { NSWorkspace.shared.open(url) }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.url, forType: .string)
        Toasts.shared.show("Link Copied", symbol: "link")
    }
}
