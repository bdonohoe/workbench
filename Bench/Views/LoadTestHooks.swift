#if DEBUG
import AppKit
import BenchKit
import QuartzCore

/// Hooks for load testing a copy of Workbench from a script, so animation
/// and scrolling costs can be measured the same way every time.
///
/// Set BENCH_LOAD_TEST=1, usually with BENCH_FAKE_CLAUDE=<script> so Claude
/// tabs run a stand-in that "works" on cue. At launch every project is
/// opened once, so each one's terminal is running. After that, the script
/// drops request files into the support folder, and each is read and
/// removed within half a second:
///
/// - `motion-request`: `full`, `calm` or `still` sets the Motion setting.
/// - `select-request`: a project's index in the list selects it.
/// - `app-request`: `hide` or `unhide`.
/// - `snapshot-request`: a PNG path. One ending in `-sidebar.png` draws only
///   the sidebar's list, since the window's materials don't draw.
/// - `scroll-request`: a label. The sidebar scrolls to the bottom and back
///   four times, one step per display frame, and a line of frame times goes
///   to `scroll-results.txt`. A label with `idle` in it times the frames
///   without scrolling. One starting with `chat` uses the chat instead.
/// - `send-request`: text the open chat sends as if typed. `big:<lines>`
///   sends a paste that many lines long. Frame times for the next two
///   seconds go to `scroll-results.txt` under the label `send`.
@MainActor
final class LoadTestHooks: NSObject {
    private static let shared = LoadTestHooks()
    private weak var store: AppStore?
    private var link: CADisplayLink?
    private var scroll: NSScrollView?
    private var label = ""
    private var scrolls = true
    private var started: CFTimeInterval = 0
    private var last: CFTimeInterval = 0
    private var frame: Double = 1.0 / 60
    private var gaps: [Double] = []
    private var position: CGFloat = 0
    private var direction: CGFloat = 1
    private var trips = 0
    /// Points a second: a brisk flick.
    private let speed: CGFloat = 1400

    static func start(store: AppStore) async {
        guard ProcessInfo.processInfo.environment["BENCH_LOAD_TEST"] != nil else { return }
        shared.store = store
        try? await Task.sleep(for: .seconds(2))
        let ids = store.projects.map(\.id)
        for id in ids {
            store.selectedProjectID = id
            try? await Task.sleep(for: .milliseconds(400))
        }
        store.selectedProjectID = ids.first
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { shared.poll() }
        }
    }

    /// Reads and removes a request file, returning what it said.
    private func take(_ name: String) -> String? {
        let file = BenchPaths.support.appendingPathComponent(name)
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        try? FileManager.default.removeItem(at: file)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var window: NSWindow? { NSApp.windows.first { $0.isVisible && !($0 is NSPanel) } }

    private func poll() {
        if let level = take("motion-request").flatMap(MotionLevel.init(rawValue:)) {
            UserDefaults.standard.set(level.rawValue, forKey: MotionLevel.key)
        }
        if let text = take("select-request"), let index = Int(text), let store, store.projects.indices.contains(index) {
            store.selectedProjectID = store.projects[index].id
        }
        switch take("app-request") {
        case "hide": NSApp.hide(nil)
        case "unhide": NSApp.unhide(nil)
        default: break
        }
        if let path = take("snapshot-request") { snapshot(to: path) }
        if link == nil, let label = take("scroll-request") { startScroll(label) }
        if let text = take("send-request") { startSend(text) }
        if take("layout-request") != nil { dumpLayout() }
    }

    /// Writes the chat scroll view's frame and each view above it, for
    /// finding a pane taller than the window.
    private func dumpLayout() {
        guard let root = window?.contentView else { return write("layout\tno window") }
        var all: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView { all.append(scroll) }
            view.subviews.forEach(walk)
        }
        walk(root)
        write("layout \(ChatDebug.scrollState)")
        for scroll in all {
            let clip = scroll.contentView.bounds
            var line = "layout scroll doc=\(Int(scroll.documentView?.frame.height ?? -1)) visible=\(Int(clip.minY))-\(Int(clip.maxY))"
            var view: NSView? = scroll
            while let current = view {
                let frame = current.convert(current.bounds, to: nil)
                let name = String(describing: type(of: current))
                let fits = name.hasPrefix("NSHostingView") || name.hasPrefix("AppKitWindowHostingView")
                    ? " fits=\(Int(current.fittingSize.width))x\(Int(current.fittingSize.height))" : ""
                line += " | \(name.prefix(60)) \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))\(fits)"
                view = current.superview
            }
            write(line)
        }
    }

    private func startSend(_ request: String) {
        var text = request
        if request.hasPrefix("big:"), let lines = Int(request.dropFirst(4)) {
            text = (1...lines).map { "Line \($0): the quick brown fox jumps over the lazy dog and keeps on running past the fence" }
                .joined(separator: "\n")
        }
        NotificationCenter.default.post(name: .loadTestSend, object: text)
        // Frames are only timed when nothing else is; a locked screen
        // never ends the last timing, and sending shouldn't wait on it.
        guard link == nil else { return }
        label = "send"
        scroll = nil
        scrolls = false
        gaps = []
        last = 0
        started = CACurrentMediaTime()
        link = window?.contentView?.displayLink(target: self, selector: #selector(tick(_:)))
        link?.add(to: .main, forMode: .common)
    }

    private func snapshot(to path: String) {
        var view = window?.contentView
        if path.hasSuffix("-sidebar.png"), let root = view { view = Self.sidebarScroll(in: root)?.documentView }
        guard let view, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    // MARK: Scrolling

    private func startScroll(_ label: String) {
        self.label = label
        let chat = label.hasPrefix("chat")
        guard let view = window?.contentView, let found = chat ? Self.chatScroll(in: view) : Self.sidebarScroll(in: view) else {
            return write("\(label)\tno \(chat ? "chat" : "sidebar") scroll view")
        }
        scroll = found
        scrolls = !label.contains("idle")
        position = 0
        direction = 1
        trips = 0
        gaps = []
        last = 0
        started = CACurrentMediaTime()
        if scrolls {
            found.contentView.scroll(to: .zero)
            found.reflectScrolledClipView(found.contentView)
        }
        link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link?.add(to: .main, forMode: .common)
    }

    /// The tallest scroll view at the window's leading edge that can scroll.
    private static func sidebarScroll(in view: NSView) -> NSScrollView? {
        var found: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView, let document = scroll.documentView,
               document.frame.height > scroll.contentView.bounds.height + 50 {
                let frame = scroll.convert(scroll.bounds, to: nil)
                if frame.minX < 40 && frame.width < 450 { found.append(scroll) }
            }
            view.subviews.forEach(walk)
        }
        walk(view)
        return found.max { $0.frame.height < $1.frame.height }
    }

    /// The widest scroll view away from the window's leading edge that can scroll.
    private static func chatScroll(in view: NSView) -> NSScrollView? {
        var found: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView, let document = scroll.documentView,
               document.frame.height > scroll.contentView.bounds.height + 50 {
                let frame = scroll.convert(scroll.bounds, to: nil)
                if frame.minX >= 40 && frame.width >= 450 { found.append(scroll) }
            }
            view.subviews.forEach(walk)
        }
        walk(view)
        return found.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    @objc private func tick(_ link: CADisplayLink) {
        if label == "send" {
            frame = link.duration > 0 ? link.duration : frame
            if last > 0 { gaps.append((link.timestamp - last) * 1000) }
            last = link.timestamp
            if CACurrentMediaTime() - started > 2 { finish() }
            return
        }
        guard let scroll, let document = scroll.documentView else { return finish() }
        frame = link.duration > 0 ? link.duration : frame
        let step = last > 0 ? link.timestamp - last : frame
        if last > 0 { gaps.append(step * 1000) }
        last = link.timestamp
        guard scrolls else {
            if CACurrentMediaTime() - started > 4 { finish() }
            return
        }
        let bottom = max(0, document.frame.height - scroll.contentView.bounds.height)
        position += direction * speed * CGFloat(step)
        if position >= bottom { position = bottom; direction = -1; trips += 1 }
        if position <= 0, direction < 0 { position = 0; direction = 1; trips += 1 }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: position))
        scroll.reflectScrolledClipView(scroll.contentView)
        if trips >= 4 { finish() }
    }

    /// Writes frames, mean, percentiles and worst gap in ms, gaps longer
    /// than one and a half frames, and frames the screen showed twice.
    private func finish() {
        link?.invalidate()
        link = nil
        defer { scroll = nil }
        let sorted = gaps.sorted()
        guard let worst = sorted.last else { return write("\(label)\tno frames") }
        let frameMS = frame * 1000
        let at = { (q: Double) in sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))] }
        let dropped = gaps.reduce(0) { $0 + max(0, Int(($1 / frameMS).rounded()) - 1) }
        write(String(format: "%@\tframes=%d\tavg=%.2f\tp50=%.2f\tp95=%.2f\tp99=%.2f\tmax=%.2f\tslow=%d\tdropped=%d\tdocHeight=%.0f",
                     label, sorted.count, sorted.reduce(0, +) / Double(sorted.count), at(0.5), at(0.95), at(0.99), worst,
                     gaps.filter { $0 > frameMS * 1.5 }.count, dropped, scroll?.documentView?.frame.height ?? 0))
    }

    private func write(_ line: String) {
        NSLog("Bench: load test %@", line)
        let file = BenchPaths.support.appendingPathComponent("scroll-results.txt")
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: file)
        }
    }
}
#endif

#if DEBUG
extension Notification.Name {
    /// A load test asking the open chat to send this text (the object).
    static let loadTestSend = Notification.Name("BenchLoadTestSend")
}
#endif
