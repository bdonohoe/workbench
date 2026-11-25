#if DEBUG
import AppKit
import QuartzCore
import SwiftUI

/// BENCH_SIDEBAR_BENCH=<count> toggles the sidebar that many times, a
/// second apart, the way its button does, and logs the frame times of
/// each animation. For checking that collapsing and expanding stays smooth.
@MainActor
final class FrameMeter: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var gaps: [CFTimeInterval] = []

    func start(in view: NSView) {
        gaps = []
        last = 0
        link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link?.add(to: .main, forMode: .common)
    }

    @objc private func tick(_ link: CADisplayLink) {
        if last > 0 { gaps.append(link.timestamp - last) }
        last = link.timestamp
    }

    /// Stops and returns a one-line summary.
    func stop() -> String {
        link?.invalidate()
        link = nil
        guard !gaps.isEmpty else { return "no frames" }
        let ms = gaps.map { $0 * 1000 }
        let slow = ms.filter { $0 > 20 }.count
        return String(format: "frames %d, avg %.1fms, worst %.1fms, over 20ms %d", ms.count,
                      ms.reduce(0, +) / Double(ms.count), ms.max() ?? 0, slow)
    }

    /// The sidebar column's width, from the split view that holds it.
    private static func sidebarWidth(in view: NSView) -> CGFloat? {
        if let split = view as? NSSplitView, let first = split.arrangedSubviews.first {
            return split.isSubviewCollapsed(first) ? 0 : first.frame.width
        }
        for sub in view.subviews { if let width = sidebarWidth(in: sub) { return width } }
        return nil
    }

    static func runSidebarBench(store: AppStore) async {
        guard let count = ProcessInfo.processInfo.environment["BENCH_SIDEBAR_BENCH"].flatMap(Int.init) else { return }
        try? await Task.sleep(for: .seconds(4))
        guard let view = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) })?.contentView else { return }
        let meter = FrameMeter()
        for index in 0..<count {
            meter.start(in: view)
            withAnimation(Theme.Motion.layout) {
                store.sidebarVisibility = store.sidebarVisibility == .detailOnly ? .all : .detailOnly
            }
            var widths: [Int] = []
            for _ in 0..<6 {
                try? await Task.sleep(for: .milliseconds(50))
                widths.append(Int(Self.sidebarWidth(in: view) ?? -1))
            }
            NSLog("Bench: sidebar widths during animation %@", widths.map(String.init).joined(separator: " "))
            try? await Task.sleep(for: .milliseconds(300))
            NSLog("Bench: sidebar bench %d %@: %@", index, store.sidebarVisibility == .detailOnly ? "collapse" : "expand", meter.stop())
            try? await Task.sleep(for: .milliseconds(400))
        }
    }
}
#endif
