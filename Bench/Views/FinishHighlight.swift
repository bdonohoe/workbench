import AppKit
import QuartzCore
import SwiftUI

/// The HDR part of a row's finish: a flash and a band of light, brighter
/// than white, laid over the regular ones in `ActivityBackground`. It only
/// draws on a display with HDR headroom, and only while the finish plays.
/// Its layers come out as soon as it ends, so nothing keeps the display in
/// HDR afterwards.
///
/// Core Animation draws it because SwiftUI's own HDR colors
/// (`Color.exposureAdjust`) come out at standard brightness in a Mac
/// window. So does a `CAGradientLayer` with HDR colors, which is why the
/// band is a solid HDR layer with a gradient for a mask.
struct FinishHighlight: NSViewRepresentable {
    /// Each change plays the highlight once. The value a row starts with
    /// plays nothing, so a row that shows up already done stays quiet.
    let plays: Int
    let color: Color
    var cornerRadius: CGFloat = 9

    /// How long the flash and the band take. `ActivityBackground` runs its
    /// own flash and band on the same clock.
    static let flashDuration = 1.2
    static let sweepDuration = 0.9
    /// How much brighter than the plain color, in stops (2 is four times).
    private static let exposure: CGFloat = 2

    func makeNSView(context: Context) -> HighlightView {
        let view = HighlightView()
        view.plays = plays
        return view
    }

    func updateNSView(_ view: HighlightView, context: Context) {
        view.layer?.cornerRadius = cornerRadius
        guard plays != view.plays else { return }
        view.plays = plays
        view.play(color: NSColor(color))
    }

    final class HighlightView: NSView {
        var plays = 0
        /// A highlight asked for before the view had a size or a window.
        private var waiting: NSColor?
        private var run = 0

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.cornerCurve = .continuous
            layer?.masksToBounds = true
        }

        required init?(coder: NSCoder) { fatalError("Not used") }

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            if let waiting { play(color: waiting) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let waiting { play(color: waiting) }
        }

        func play(color: NSColor) {
            guard let layer, let window, bounds.width > 0, bounds.height > 0 else {
                waiting = color
                return
            }
            waiting = nil
            // Only where the display can go past white. Anywhere else the
            // regular highlight is the whole show.
            guard let screen = window.screen,
                  screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1,
                  let base = color.usingColorSpace(.sRGB) else { return }
            let bright = NSColor(red: base.redComponent, green: base.greenComponent, blue: base.blueComponent,
                                 alpha: 1, exposure: FinishHighlight.exposure).cgColor
            let size = bounds.size
            run += 1
            let thisRun = run

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.sublayers?.forEach { $0.removeFromSuperlayer() }
            CATransaction.setCompletionBlock { [weak self] in
                // Out with the layers, and the display settles back.
                guard let self, self.run == thisRun else { return }
                self.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
            }

            let flash = CALayer()
            flash.frame = CGRect(origin: .zero, size: size)
            flash.backgroundColor = bright
            flash.preferredDynamicRange = .high
            flash.opacity = 0
            layer.addSublayer(flash)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.3
            fade.toValue = 0
            fade.duration = FinishHighlight.flashDuration
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            flash.add(fade, forKey: "fade")

            // The same band as the regular one: half the row wide, soft at
            // both edges, resting past the trailing edge.
            let width = max(60, size.width * 0.5)
            let band = CALayer()
            band.bounds = CGRect(x: 0, y: 0, width: width, height: size.height)
            band.backgroundColor = bright
            band.preferredDynamicRange = .high
            band.opacity = 0.55
            let soft = CAGradientLayer()
            soft.frame = band.bounds
            soft.colors = [NSColor.black.withAlphaComponent(0).cgColor, NSColor.black.cgColor,
                           NSColor.black.withAlphaComponent(0).cgColor]
            soft.startPoint = CGPoint(x: 0, y: 0.5)
            soft.endPoint = CGPoint(x: 1, y: 0.5)
            band.mask = soft
            band.position = CGPoint(x: size.width + width / 2, y: size.height / 2)
            layer.addSublayer(band)
            let cross = CABasicAnimation(keyPath: "position.x")
            cross.fromValue = -width / 2
            cross.toValue = size.width + width / 2
            cross.duration = FinishHighlight.sweepDuration
            cross.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            band.add(cross, forKey: "cross")

            CATransaction.commit()
        }
    }
}
