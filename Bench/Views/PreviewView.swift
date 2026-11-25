import Observation
import SwiftUI
import WebKit

/// Keeps one web page per browser tab, so switching tabs doesn't reload it
/// or lose its scroll position and history.
@Observable
final class PreviewPages {
    /// A request to put the cursor in a tab's address field. The count
    /// makes each one new, so asking twice works twice.
    struct AddressFocus: Equatable {
        var tab: UUID
        var count: Int
    }

    private var pages: [UUID: WebPage] = [:]
    private var zooms: [UUID: Double] = [:]
    private(set) var addressFocus: AddressFocus?
    /// Opens a page a link asked for in a tab of its own, after the tab
    /// the link was in. Set at launch.
    @ObservationIgnored var openInNewTab: ((URL, UUID) -> Void)?

    func page(for tabID: UUID, url: URL?) -> WebPage {
        if let page = pages[tabID] { return page }
        let page = WebPage(navigationDecider: BrowserNavigation { [weak self] url in
            self?.openInNewTab?(url, tabID)
        })
        // Inspect Element in the page's menu: these are often dev servers.
        page.isInspectable = true
        if let url { page.load(URLRequest(url: url)) }
        pages[tabID] = page
        return page
    }

    /// A tab's page, if the tab has been on screen to make one.
    func existing(_ tabID: UUID) -> WebPage? { pages[tabID] }

    /// The address a tab's page is on now, after any links followed.
    func currentURL(for tabID: UUID) -> URL? { pages[tabID]?.url }

    func focusAddress(of tabID: UUID) {
        addressFocus = AddressFocus(tab: tabID, count: (addressFocus?.count ?? 0) + 1)
    }

    func prune(keeping tabIDs: Set<UUID>) {
        for id in pages.keys where !tabIDs.contains(id) {
            pages[id]?.stopLoading()
            pages[id] = nil
            zooms[id] = nil
        }
    }

    // MARK: Zoom

    static let zoomSteps: [Double] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]

    func zoom(of tabID: UUID) -> Double { zooms[tabID] ?? 1 }

    func canZoom(_ tabID: UUID, by steps: Int) -> Bool {
        let index = Self.zoomSteps.firstIndex(of: zoom(of: tabID)) ?? 5
        return Self.zoomSteps.indices.contains(index + steps)
    }

    /// One step bigger or smaller.
    func zoom(_ tabID: UUID, by steps: Int) {
        guard canZoom(tabID, by: steps) else { return }
        let index = Self.zoomSteps.firstIndex(of: zoom(of: tabID)) ?? 5
        zooms[tabID] = Self.zoomSteps[index + steps]
        applyZoom(tabID)
    }

    func resetZoom(_ tabID: UUID) {
        zooms[tabID] = nil
        applyZoom(tabID)
    }

    /// Sets the page's size. A new page starts at its own size, so this
    /// runs again each time the tab goes somewhere.
    func applyZoom(_ tabID: UUID) {
        guard let page = pages[tabID], page.url != nil else { return }
        let level = zoom(of: tabID)
        Task {
            _ = try? await page.callJavaScript("document.documentElement.style.zoom = level",
                                               arguments: ["level": level == 1 ? "" : String(level)])
        }
    }
}

extension WebPage {
    var canGoBack: Bool { !backForwardList.backList.isEmpty }
    var canGoForward: Bool { !backForwardList.forwardList.isEmpty }

    func goBack() {
        if let item = backForwardList.backList.last { load(item) }
    }

    func goForward() {
        if let item = backForwardList.forwardList.first { load(item) }
    }
}

/// Where a browser tab's links go: pages stay in the tab, a link that
/// asks for a new window gets a new tab, and anything that isn't a web
/// page (mail, another app's links) goes to the app that handles it.
private struct BrowserNavigation: WebPage.NavigationDeciding {
    private static let pageSchemes: Set<String> = ["http", "https", "file", "about", "blob", "data", "javascript"]
    let openInNewTab: (URL) -> Void

    mutating func decidePolicy(for action: WebPage.NavigationAction,
                               preferences: inout WebPage.NavigationPreferences) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .allow }
        if let scheme = url.scheme?.lowercased(), !Self.pageSchemes.contains(scheme) {
            NSWorkspace.shared.open(url)
            return .cancel
        }
        // No frame to load into: target="_blank", or a script's window.open.
        if action.target == nil {
            openInNewTab(url)
            return .cancel
        }
        return .allow
    }
}

/// A browser tab: one of Claude's published pages, a local dev server, or
/// any site you type in.
struct PreviewView: View {
    let page: WebPage
    /// Where the tab started, for the Home button. nil for a tab opened
    /// empty, which has nowhere to go back to.
    let home: URL?
    let tabID: UUID
    let projectID: UUID

    @Environment(AppStore.self) private var store
    @Environment(PreviewPages.self) private var previews
    /// The field's text: the short form at rest, the whole address while
    /// you're editing it.
    @State private var address = ""
    /// Where the tab was just sent, shown until the page gets there.
    @State private var destination: URL?
    /// The last page you asked for, if it didn't load, and why.
    @State private var failure: (url: URL, reason: String)?
    /// Counts the pages asked for, so a late failure of an earlier one
    /// isn't taken for the latest.
    @State private var loads = 0
    @State private var finding = false
    /// True while the address is a text field. At rest it's a label, so
    /// the field can't pick up the keys just by being the only one around.
    @State private var editingAddress = false
    @FocusState private var addressFocused: Bool

    private var currentURL: URL? { destination ?? failure?.url ?? page.url }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .onAppear {
            address = shortAddress
            // An empty tab is waiting for an address.
            if currentURL == nil { editAddress() }
        }
        .onChange(of: previews.addressFocus) { _, request in
            if request?.tab == tabID { editAddress() }
        }
        .onChange(of: addressFocused) { _, focused in
            if !focused { stopEditing() }
        }
        .onChange(of: page.url) { _, url in
            if url != nil { destination = nil }
            if !editingAddress { address = shortAddress }
            noteWhereThePageIs()
            if previews.zoom(of: tabID) != 1 { previews.applyZoom(tabID) }
        }
        .onChange(of: page.title) { noteWhereThePageIs() }
        .onChange(of: page.isLoading) { _, loading in
            // Going anywhere else, by a link or Back, leaves a failure behind.
            if loading, destination == nil { failure = nil }
            if !loading, previews.zoom(of: tabID) != 1 { previews.applyZoom(tabID) }
        }
    }

    // MARK: Page

    @ViewBuilder private var content: some View {
        if let failure {
            message(symbol: "wifi.exclamationmark", title: "This page didn't open", detail: failure.reason) {
                Button("Try Again") { load(failure.url) }
            }
        } else if currentURL == nil {
            message(symbol: "globe", title: "Search or enter an address",
                    detail: "Type a site, a search, or just a port number for a server on this Mac.") { EmptyView() }
        } else {
            WebView(page)
                .webViewBackForwardNavigationGestures(.enabled)
                .findNavigator(isPresented: $finding)
                .replaceDisabled()
        }
    }

    private func message(symbol: String, title: String, detail: String, @ViewBuilder action: () -> some View) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 4)
            Text(title)
                .font(.ui(size: 15, weight: .semibold))
            Text(detail)
                .font(.ui(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            action()
                .padding(.top, 6)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Header

    private var toolbar: some View {
        HStack(spacing: 4) {
            button("chevron.left", help: "Back (⌘[)", disabled: !page.canGoBack) { page.goBack() }
            button("chevron.right", help: "Forward", disabled: !page.canGoForward) { page.goForward() }
            if page.isLoading {
                button("xmark", help: "Stop") { page.stopLoading() }
            } else {
                button("arrow.clockwise", help: "Reload (⌘R)", disabled: currentURL == nil) {
                    if let failure { load(failure.url) } else { page.reload() }
                }
                .keyboardShortcut("r")
            }

            addressField
                .padding(.horizontal, 4)

            if let home {
                button("house", help: "Back to \(BrowserAddress.display(home))", disabled: currentURL == home) { load(home) }
            }
            button("safari", help: "Open in your browser", disabled: currentURL == nil) {
                if let url = currentURL { NSWorkspace.shared.open(url) }
            }
        }
        .padding(.horizontal, 8)
        // The same height as the file and diff headers beside it.
        .frame(height: Theme.Layout.paneHeader)
        // Along the header's bottom edge, clear of the address.
        .overlay(alignment: .bottom) { progressLine }
        .background { findShortcut }
    }

    private var addressField: some View {
        ZStack {
            if editingAddress {
                TextField("Search or enter address", text: $address)
                    .textFieldStyle(.plain)
                    .font(.ui(size: 12))
                    .focused($addressFocused)
                    .onSubmit(go)
                    .onExitCommand(perform: stopEditing)
                    .onAppear(perform: focusAddress)
            } else {
                // The site and its lock; a click turns it into the field.
                HStack(spacing: 5) {
                    if let mark = securityMark {
                        Image(systemName: mark.symbol)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(mark.warns ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                            .help(mark.help)
                    }
                    Text(address.isEmpty ? "Search or enter address" : address)
                        .font(.ui(size: 12))
                        .foregroundStyle(address.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(editingAddress ? 0.04 : 0.06)))
        .overlay {
            if editingAddress {
                RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.accent.opacity(0.7), lineWidth: 1.5)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if !editingAddress { editAddress() } }
        .accessibilityAddTraits(editingAddress ? [] : .isButton)
        .accessibilityLabel(editingAddress ? "Address" : "Address, \(address)")
    }

    /// How far the page has loaded, as a thin line that fades when done.
    private var progressLine: some View {
        GeometryReader { proxy in
            Rectangle()
                .fill(Theme.accent)
                .frame(width: proxy.size.width * max(0.08, page.estimatedProgress))
                .animation(.easeOut(duration: 0.2), value: page.estimatedProgress)
        }
        .frame(height: 2)
        .opacity(page.isLoading ? 1 : 0)
        .animation(.easeOut(duration: page.isLoading ? 0 : 0.3), value: page.isLoading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// ⌘F while the tab is on screen. Out of sight: the bar it opens is
    /// the control.
    private var findShortcut: some View {
        Button("Find on Page") { finding = true }
            .keyboardShortcut("f")
            .disabled(currentURL == nil || failure != nil)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    private func button(_ symbol: String, help: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.ui(size: 12, weight: .medium))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(disabled)
        .help(help)
    }

    // MARK: Address

    /// What the field shows at rest: the page's name for one of Claude's
    /// pages (its address is an id), the site for anything else.
    private var shortAddress: String {
        guard let url = currentURL else { return "" }
        return artifactTitle(url) ?? BrowserAddress.display(url)
    }

    /// A lock for an encrypted page, a warning for one that isn't. Local
    /// servers get neither: plain http is normal there.
    private var securityMark: (symbol: String, help: String, warns: Bool)? {
        guard destination == nil, let url = page.url, let host = url.host(), !BrowserAddress.isLocal(host: host) else { return nil }
        if url.scheme == "https", page.hasOnlySecureContent {
            return ("lock.fill", "Your connection to \(host) is encrypted", false)
        }
        guard url.scheme == "http" || url.scheme == "https" else { return nil }
        return ("exclamationmark.triangle.fill", "Not secure: parts of this page aren't encrypted", true)
    }

    private func artifactTitle(_ url: URL) -> String? {
        guard ArtifactLinks.isArtifact(url), let project = store.project(projectID) else { return nil }
        return ArtifactLibrary.shared.links(for: project).first { $0.url == url.absoluteString }?.title
    }

    /// Turns the address into a field holding the whole address, selected
    /// and ready to type over.
    private func editAddress() {
        if editingAddress {
            focusAddress()
        } else {
            address = currentURL?.absoluteString ?? ""
            editingAddress = true
        }
    }

    /// Back to the label, with whatever was typed thrown away.
    private func stopEditing() {
        editingAddress = false
        address = shortAddress
    }

    /// Gives the field the keys and selects what's in it, once it's there.
    private func focusAddress() {
        addressFocused = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard editingAddress, let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isFieldEditor else { return }
            editor.selectAll(nil)
        }
    }

    /// Loads what was typed.
    private func go() {
        guard let url = BrowserAddress.url(from: address) else { return }
        load(url)
        stopEditing()
    }

    private func load(_ url: URL?) {
        guard let url else { return }
        destination = url
        failure = nil
        loads += 1
        let load = loads
        Task {
            do {
                for try await _ in page.load(URLRequest(url: url)) {}
            } catch {
                // Going somewhere else before this one finished isn't a failure.
                var cause = error
                if case WebPage.NavigationError.failedProvisionalNavigation(let underlying) = error { cause = underlying }
                let code = (cause as NSError).code
                guard load == loads, code != NSURLErrorCancelled, code != 102 else { return }
                failure = (url, cause.localizedDescription)
                destination = nil
                if !editingAddress { address = shortAddress }
            }
        }
    }

    /// Keeps the tab's name and saved address in step with the page.
    private func noteWhereThePageIs() {
        guard let url = page.url else { return }
        let title = artifactTitle(url) ?? (page.title.isEmpty ? BrowserAddress.display(url) : page.title)
        store.notePage(url: url, title: title, tab: tabID, in: projectID)
    }
}
