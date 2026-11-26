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

    private var pages: [UUID: BrowserPage] = [:]
    private var zooms: [UUID: Double] = [:]
    private(set) var addressFocus: AddressFocus?
    private(set) var findRequest: FindRequest?

    /// A Find command from the menu, for a tab's page. The count makes
    /// each one new, as for the address.
    struct FindRequest: Equatable {
        enum Step { case show, next, previous }
        var tab: UUID
        var step: Step
        var count: Int
    }

    func find(_ step: FindRequest.Step, in tabID: UUID) {
        findRequest = FindRequest(tab: tabID, step: step, count: (findRequest?.count ?? 0) + 1)
    }
    /// Opens a page a link asked for in a tab of its own, after the tab
    /// the link was in. Set at launch.
    @ObservationIgnored var openInNewTab: ((URL, UUID) -> Void)?

    func page(for tabID: UUID, url: URL?) -> BrowserPage {
        if let page = pages[tabID] { return page }
        let page = BrowserPage { [weak self] url in
            self?.openInNewTab?(url, tabID)
        }
        if let url { page.load(url) }
        pages[tabID] = page
        return page
    }

    /// A tab's page, if the tab has been on screen to make one.
    func existing(_ tabID: UUID) -> BrowserPage? { pages[tabID] }

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
        page.run("document.documentElement.style.zoom = level", arguments: ["level": level == 1 ? "" : String(level)])
    }
}

/// One browser tab's page: a web view, and what the tab's header shows
/// about it. WebKit's own `WebPage` does this from macOS 26; Workbench
/// runs on macOS 15 too, so this is built on `WKWebView`, which both have.
@Observable
final class BrowserPage: NSObject, WKNavigationDelegate {
    private static let pageSchemes: Set<String> = ["http", "https", "file", "about", "blob", "data", "javascript"]

    @ObservationIgnored let webView: WKWebView
    private(set) var url: URL?
    private(set) var title = ""
    private(set) var isLoading = false
    private(set) var estimatedProgress = 0.0
    private(set) var hasOnlySecureContent = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false

    @ObservationIgnored private let openInNewTab: (URL) -> Void
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    /// The page last asked for by `load`, and who to tell if it fails.
    @ObservationIgnored private var requested: (navigation: WKNavigation, failed: (Error) -> Void)?

    init(openInNewTab: @escaping (URL) -> Void) {
        self.openInNewTab = openInNewTab
        webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        // Inspect Element in the page's menu: these are often dev servers.
        webView.isInspectable = true
        watch(\.url)
        watch(\.title)
        watch(\.isLoading)
        watch(\.estimatedProgress)
        watch(\.hasOnlySecureContent)
        watch(\.canGoBack)
        watch(\.canGoForward)
    }

    /// Copies the web view's state over whenever this part of it changes.
    private func watch<Value>(_ keyPath: KeyPath<WKWebView, Value>) {
        observations.append(webView.observe(keyPath) { [weak self] _, _ in
            // WebKit changes these on the main thread.
            MainActor.assumeIsolated { self?.sync() }
        })
    }

    /// Only what changed is written, so views watching one value aren't
    /// redrawn for another.
    private func sync() {
        if url != webView.url { url = webView.url }
        let newTitle = webView.title ?? ""
        if title != newTitle { title = newTitle }
        if isLoading != webView.isLoading { isLoading = webView.isLoading }
        if estimatedProgress != webView.estimatedProgress { estimatedProgress = webView.estimatedProgress }
        if hasOnlySecureContent != webView.hasOnlySecureContent { hasOnlySecureContent = webView.hasOnlySecureContent }
        if canGoBack != webView.canGoBack { canGoBack = webView.canGoBack }
        if canGoForward != webView.canGoForward { canGoForward = webView.canGoForward }
    }

    /// Goes to an address. `failed` hears about it if the page doesn't
    /// open, unless another `load` has replaced this one by then.
    func load(_ url: URL, failed: @escaping (Error) -> Void = { _ in }) {
        requested = nil
        guard let navigation = webView.load(URLRequest(url: url)) else { return }
        requested = (navigation, failed)
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }
    func stopLoading() { webView.stopLoading() }

    /// Runs a script in the page, as the body of a function taking
    /// `arguments`. Its result and any error are dropped.
    func run(_ script: String, arguments: [String: Any] = [:]) {
        webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page, completionHandler: nil)
    }

    /// Where Find on Page stands: how many places the text appears, and
    /// which of them is the one shown (counting from 0).
    struct FindResult: Equatable {
        var count = 0
        var index = -1
    }

    /// Marks every place the text appears on the page and scrolls to the
    /// next (or previous) one, wrapping at the ends. An empty text clears
    /// the marks.
    ///
    /// The page does this itself, with a script: WebKit's own find only
    /// selects the match, and a selection doesn't show while the keys are
    /// in the find bar and not the page.
    func find(_ text: String, backwards: Bool = false) async -> FindResult {
        await withCheckedContinuation { done in
            webView.callAsyncJavaScript(Self.findScript, arguments: ["text": text, "backwards": backwards],
                                        in: nil, in: Self.findWorld) { result in
                var found = FindResult()
                if case .success(let value) = result, let answer = value as? [String: Any] {
                    found.count = answer["count"] as? Int ?? 0
                    found.index = answer["index"] as? Int ?? -1
                }
                done.resume(returning: found)
            }
        }
    }

    func clearFind() {
        webView.callAsyncJavaScript(Self.findScript, arguments: ["text": "", "backwards": false],
                                    in: nil, in: Self.findWorld, completionHandler: nil)
    }

    /// The find script's own corner of the page, so its bookkeeping and
    /// the page's scripts can't see each other.
    private static let findWorld = WKContentWorld.world(name: "WorkbenchFind")

    /// Finds `text` in the page's text and paints the matches with CSS
    /// highlights, which change nothing in the page itself. It keeps the
    /// matches between calls, so the same text again steps to the next.
    /// A match has to sit inside one run of text: one that crosses a
    /// change of style (half of it bold, say) isn't found.
    private static let findScript = """
        const state = window.__workbenchFind || (window.__workbenchFind = { text: null, ranges: [], index: -1 });
        const none = { count: 0, index: -1 };
        if (!window.CSS || !CSS.highlights || !document.body) { return none; }
        const clear = () => {
            CSS.highlights.delete('workbench-find');
            CSS.highlights.delete('workbench-find-current');
        };
        if (!text) {
            clear();
            state.text = null; state.ranges = []; state.index = -1;
            return none;
        }
        if (!state.sheet) {
            state.sheet = new CSSStyleSheet();
            state.sheet.replaceSync(
                '::highlight(workbench-find) { background-color: rgba(255, 214, 10, 0.45); }' +
                '::highlight(workbench-find-current) { background-color: rgb(255, 149, 0); color: black; }');
            document.adoptedStyleSheets = [...document.adoptedStyleSheets, state.sheet];
        }
        const stale = state.ranges.some(range => !range.startContainer.isConnected);
        if (text !== state.text || stale) {
            const needle = text.toLowerCase();
            const ranges = [];
            const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
                acceptNode(node) {
                    const parent = node.parentElement;
                    if (!parent || parent.closest('script, style, noscript, template')) { return NodeFilter.FILTER_REJECT; }
                    return NodeFilter.FILTER_ACCEPT;
                }
            });
            for (let node = walker.nextNode(); node && ranges.length < 2000; node = walker.nextNode()) {
                const hay = node.data.toLowerCase();
                // Lowercasing changes a few characters' length; skip those.
                if (hay.length !== node.data.length) { continue; }
                for (let at = hay.indexOf(needle); at !== -1 && ranges.length < 2000; at = hay.indexOf(needle, at + needle.length)) {
                    const range = new Range();
                    range.setStart(node, at);
                    range.setEnd(node, at + needle.length);
                    // Text that isn't drawn has no boxes.
                    if (range.getClientRects().length) { ranges.push(range); }
                }
            }
            state.text = text; state.ranges = ranges; state.index = -1;
        }
        const count = state.ranges.length;
        if (!count) { clear(); return none; }
        if (state.index < 0) {
            state.index = backwards ? count - 1 : 0;
        } else {
            state.index = (state.index + (backwards ? -1 : 1) + count) % count;
        }
        const current = state.ranges[state.index];
        CSS.highlights.set('workbench-find', new Highlight(...state.ranges));
        const mark = new Highlight(current);
        mark.priority = 1;
        CSS.highlights.set('workbench-find-current', mark);
        const box = current.getBoundingClientRect();
        if (box.top < 0 || box.bottom > window.innerHeight || box.left < 0 || box.right > window.innerWidth) {
            current.startContainer.parentElement.scrollIntoView({ block: 'center', inline: 'nearest' });
        }
        return { count: count, index: state.index };
        """

    // MARK: WKNavigationDelegate

    /// Where a browser tab's links go: pages stay in the tab, a link that
    /// asks for a new window gets a new tab, and anything that isn't a web
    /// page (mail, another app's links) goes to the app that handles it.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .allow }
        if let scheme = url.scheme?.lowercased(), !Self.pageSchemes.contains(scheme) {
            NSWorkspace.shared.open(url)
            return .cancel
        }
        // No frame to load into: target="_blank", or a script's window.open.
        if navigationAction.targetFrame == nil {
            openInNewTab(url)
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if requested?.navigation === navigation { requested = nil }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fail(navigation, error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail(navigation, error)
    }

    private func fail(_ navigation: WKNavigation?, _ error: Error) {
        guard let requested, requested.navigation === navigation else { return }
        self.requested = nil
        requested.failed(error)
    }
}

/// Shows a tab's web view. The view belongs to the page, not to this, so
/// it's the same one (same scroll position, same history) each time the
/// tab comes back on screen.
private struct BrowserWebView: NSViewRepresentable {
    let page: BrowserPage

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        attach(to: container)
    }

    private func attach(to container: NSView) {
        let webView = page.webView
        guard webView.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }
}

/// A browser tab: one of Claude's published pages, a local dev server, or
/// any site you type in.
struct PreviewView: View {
    let page: BrowserPage
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
    @State private var findText = ""
    /// What the last search found. Nil until one is made, and again
    /// when the text changes.
    @State private var findResult: BrowserPage.FindResult?
    @FocusState private var findFocused: Bool
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
        .onChange(of: previews.findRequest) { _, request in
            guard let request, request.tab == tabID, currentURL != nil, failure == nil else { return }
            // Next and Previous with nothing to look for open the bar.
            if request.step == .show || !finding || findText.isEmpty {
                finding = true
                findFocused = true
            } else {
                find(backwards: request.step == .previous)
            }
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
            VStack(spacing: 0) {
                if finding {
                    findBar
                    Divider()
                }
                BrowserWebView(page: page)
            }
        }
    }

    /// Find on Page: Return for the next match, Shift-Return for the one
    /// before, Escape to close.
    private var findBar: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.ui(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Find on page", text: $findText)
                .textFieldStyle(.plain)
                .font(.ui(size: 12))
                .focused($findFocused)
                .onSubmit { find(backwards: NSEvent.modifierFlags.contains(.shift)) }
                .onExitCommand(perform: stopFinding)
                .onChange(of: findText) { findResult = nil }
            if let findResult {
                Text(findResult.count == 0 ? "Not found" : "\(findResult.index + 1) of \(findResult.count)")
                    .font(.ui(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            button("chevron.up", help: "Previous match (⇧↩)", disabled: findText.isEmpty) { find(backwards: true) }
            button("chevron.down", help: "Next match (↩)", disabled: findText.isEmpty) { find(backwards: false) }
            Button("Done", action: stopFinding)
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .onAppear { findFocused = true }
    }

    private func find(backwards: Bool) {
        let text = findText
        guard !text.isEmpty else { return }
        Task {
            let found = await page.find(text, backwards: backwards)
            if text == findText, finding { findResult = found }
        }
    }

    private func stopFinding() {
        finding = false
        findResult = nil
        page.clearFind()
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
        Button("Find on Page") {
            finding = true
            findFocused = true
        }
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
        page.load(url) { error in
            // Going somewhere else before this one finished isn't a failure.
            let code = (error as NSError).code
            guard load == loads, code != NSURLErrorCancelled, code != 102 else { return }
            failure = (url, error.localizedDescription)
            destination = nil
            if !editingAddress { address = shortAddress }
        }
    }

    /// Keeps the tab's name and saved address in step with the page.
    private func noteWhereThePageIs() {
        guard let url = page.url else { return }
        let title = artifactTitle(url) ?? (page.title.isEmpty ? BrowserAddress.display(url) : page.title)
        store.notePage(url: url, title: title, tab: tabID, in: projectID)
    }
}
