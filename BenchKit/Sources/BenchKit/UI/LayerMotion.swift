#if os(macOS)
import AppKit
import QuartzCore
import SwiftUI

/// Motion that never stops (a working row's sparkles, a waiting dot's
/// breath, Claude's spinning glyph), drawn by Core Animation instead of
/// SwiftUI.
///
/// A SwiftUI animation redraws in the app on every frame, and every frame
/// makes AppKit lay out the whole window again. With a few busy projects
/// in the sidebar that kept the main thread busy most of the time. These
/// layers are set up once and the window server plays them, so the app
/// does no work per frame.
///
/// Every animation is timed from the wall clock, so rows that share a
/// motion stay in step, the same as the SwiftUI versions did.
public struct LayerMotion: NSViewRepresentable {
    public enum Kind: Equatable {
        /// A light band that sweeps across, and four-point sparkles that
        /// twinkle and drift.
        case sparkles(NSColor)
        /// A tint that brightens and dims, from `from` to `to` opacity
        /// and back over `period` seconds.
        case breathing(NSColor, from: Double = 0.1, to: Double = 0.26, period: Double = 2)
        /// The symbols Claude Code cycles through while it works.
        case glyphs(NSColor, size: CGFloat)
        /// A dot with a ring that grows and fades. The ring goes from
        /// `ring` to `ringTo` across, and from `opacity` to `opacityTo`.
        case pulse(NSColor, dot: CGFloat, ring: CGFloat, ringTo: CGFloat,
                   opacity: CGFloat, opacityTo: CGFloat, period: Double)
        /// A soft radial glow from `center` (in unit coordinates) out to
        /// `reach` of the longer side, breathing brighter every few seconds.
        case glow(NSColor, center: CGPoint, reach: CGFloat)
        /// A turning arc, like a busy row's spinner.
        case arc(NSColor, lineWidth: CGFloat)
        /// A block that is on, then off, like a terminal's cursor.
        case blink(NSColor, period: Double = 1.2)
        /// Comets of light that run around the border, tails behind them,
        /// `count` of them evenly spaced. One lap takes `period` seconds.
        /// The border is a rounded rectangle of the view's corner radius.
        case beam(NSColor, lineWidth: CGFloat = 1.5, count: Int = 2, period: Double = 3.2)
    }

    public let kind: Kind
    public var cornerRadius: CGFloat = 0

    public init(kind: Kind, cornerRadius: CGFloat = 0) {
        self.kind = kind
        self.cornerRadius = cornerRadius
    }

    public func makeNSView(context: Context) -> MotionView { MotionView() }

    public func updateNSView(_ view: MotionView, context: Context) {
        view.update(kind: kind, cornerRadius: cornerRadius)
    }

    public final class MotionView: NSView {
        private var kind: Kind?
        private var cornerRadius: CGFloat = 0
        private var built: (size: CGSize, scale: CGFloat)?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.cornerCurve = .continuous
        }

        required init?(coder: NSCoder) { fatalError("Not used") }

        /// Top-left origin, like SwiftUI, so positions read the same.
        public override var isFlipped: Bool { true }
        public override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func update(kind: Kind, cornerRadius: CGFloat) {
            guard kind != self.kind || cornerRadius != self.cornerRadius else { return }
            self.kind = kind
            self.cornerRadius = cornerRadius
            built = nil
            needsLayout = true
        }

        public override func layout() {
            super.layout()
            rebuildIfNeeded()
        }

        public override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // A layer can lose its animations on the way out of a window.
            built = nil
            rebuildIfNeeded()
        }

        public override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            built = nil
            rebuildIfNeeded()
        }

        private func rebuildIfNeeded() {
            guard let layer, let kind, let window, bounds.width > 0, bounds.height > 0 else { return }
            let scale = window.backingScaleFactor
            if let built, built.size == bounds.size, built.scale == scale { return }
            built = (bounds.size, scale)

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.sublayers?.forEach { $0.removeFromSuperlayer() }
            layer.cornerRadius = cornerRadius
            switch kind {
            case .sparkles, .breathing, .glow, .blink: layer.masksToBounds = true
            case .glyphs, .pulse, .arc, .beam: layer.masksToBounds = false
            }
            Self.build(kind, in: layer, size: bounds.size, scale: scale, cornerRadius: cornerRadius)
            CATransaction.commit()
        }

        // MARK: Building

        private static func build(_ kind: Kind, in layer: CALayer, size: CGSize, scale: CGFloat, cornerRadius: CGFloat) {
            switch kind {
            case .sparkles(let color): sparkles(color, in: layer, size: size, scale: scale)
            case let .breathing(color, from, to, period): breathing(color, from: from, to: to, period: period, in: layer, size: size)
            case .glyphs(let color, let glyphSize): glyphs(color, glyphSize: glyphSize, in: layer, size: size, scale: scale)
            case let .pulse(color, dot, ring, ringTo, opacity, opacityTo, period):
                pulse(color, dot: dot, ring: ring, ringTo: ringTo, opacity: opacity, opacityTo: opacityTo,
                      period: period, in: layer, size: size, scale: scale)
            case let .glow(color, center, reach): glow(color, center: center, reach: reach, in: layer, size: size)
            case let .arc(color, lineWidth): arc(color, lineWidth: lineWidth, in: layer, size: size, scale: scale)
            case let .blink(color, period): blink(color, period: period, in: layer, size: size)
            case let .beam(color, lineWidth, count, period):
                beam(color, lineWidth: lineWidth, count: count, period: period, cornerRadius: cornerRadius,
                     in: layer, size: size, scale: scale)
            }
        }

        /// Each comet is a stack of dashes that share a head and get
        /// shorter, so the light builds toward the front and thins out
        /// behind. Moving a dash along the border is one animated number,
        /// its phase, so the comets keep an even speed around the corners.
        ///
        /// Every dash is a layer the window server strokes again on each
        /// frame, so there are only a few, and the glow at the front is a
        /// wider faint stroke instead of a blurred shadow.
        private static func beam(_ color: NSColor, lineWidth: CGFloat, count: Int, period: Double, cornerRadius: CGFloat,
                                 in layer: CALayer, size: CGSize, scale: CGFloat) {
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
            guard rect.width > 0, rect.height > 0, count > 0 else { return }
            let radius = max(0, min(cornerRadius - lineWidth / 2, min(rect.width, rect.height) / 2))
            let path = RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath
            let around = length(of: path)
            guard around > 0 else { return }
            let spacing = around / CGFloat(count)
            let tail = min(spacing * 0.7, 340)
            let t = now

            func dash(length: CGFloat, width: CGFloat, alpha: CGFloat) -> CAShapeLayer {
                let line = CAShapeLayer()
                line.frame = CGRect(origin: .zero, size: size)
                line.path = path
                line.fillColor = nil
                line.strokeColor = color.withAlphaComponent(alpha).cgColor
                line.lineWidth = width
                line.lineCap = .round
                line.lineDashPattern = [NSNumber(value: Double(length)), NSNumber(value: Double(spacing - length))]
                line.contentsScale = scale
                // The head sits at the same place for every length.
                let run = CABasicAnimation(keyPath: "lineDashPhase")
                run.fromValue = length
                run.toValue = length - around
                run.timingFunction = CAMediaTimingFunction(name: .linear)
                layer.addSublayer(line)
                line.add(repeating(run, period: period, at: t), forKey: "run")
                return line
            }

            // A soft glow around the front of each comet: two wide, faint
            // strokes, the wider one fainter.
            _ = dash(length: tail * 0.3, width: lineWidth + 6, alpha: 0.06)
            _ = dash(length: tail * 0.28, width: lineWidth + 3, alpha: 0.11)

            // The tail: each dash is this much of its length and this
            // faint, picked so that where they overlap the light falls off
            // from the head the way a smooth fade would.
            let tailDashes: [(length: CGFloat, alpha: CGFloat)] = [
                (1, 0.10), (0.8, 0.20), (0.6, 0.24), (0.4, 0.31), (0.2, 0.47), (0.06, 0.60),
            ]
            for part in tailDashes {
                _ = dash(length: tail * part.length, width: lineWidth, alpha: part.alpha)
            }
        }

        /// How long a path is, with its curves measured as short lines.
        private static func length(of path: CGPath) -> CGFloat {
            var total: CGFloat = 0
            var current = CGPoint.zero
            var start = CGPoint.zero
            func line(to point: CGPoint) {
                total += hypot(point.x - current.x, point.y - current.y)
                current = point
            }
            path.applyWithBlock { element in
                let points = element.pointee.points
                switch element.pointee.type {
                case .moveToPoint:
                    current = points[0]
                    start = points[0]
                case .addLineToPoint:
                    line(to: points[0])
                case .addQuadCurveToPoint:
                    let (from, control, to) = (current, points[0], points[1])
                    for step in 1...24 {
                        let t = CGFloat(step) / 24, u = 1 - t
                        line(to: CGPoint(x: u * u * from.x + 2 * u * t * control.x + t * t * to.x,
                                         y: u * u * from.y + 2 * u * t * control.y + t * t * to.y))
                    }
                case .addCurveToPoint:
                    let (from, c1, c2, to) = (current, points[0], points[1], points[2])
                    for step in 1...24 {
                        let t = CGFloat(step) / 24, u = 1 - t
                        let (a, b, c, d) = (u * u * u, 3 * u * u * t, 3 * u * t * t, t * t * t)
                        line(to: CGPoint(x: a * from.x + b * c1.x + c * c2.x + d * to.x,
                                         y: a * from.y + b * c1.y + c * c2.y + d * to.y))
                    }
                case .closeSubpath:
                    line(to: start)
                @unknown default:
                    break
                }
            }
            return total
        }

        private struct Sparkle { var x: Double, y: Double, size: Double, phase: Double, speed: Double }

        private static let sparkleSpots: [Sparkle] = {
            var seed: UInt64 = 0x9E3779B97F4A7C15
            func next() -> Double {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return Double(seed >> 33) / Double(1 << 31)
            }
            return (0..<14).map { _ in
                Sparkle(x: next(), y: next(), size: 2 + next() * 2.5, phase: next() * .pi * 2, speed: 1.4 + next() * 1.6)
            }
        }()

        private static func sparkles(_ color: NSColor, in layer: CALayer, size: CGSize, scale: CGFloat) {
            let t = now

            // The sweep crosses in 1.6s, then rests off the edge for a moment.
            let band = size.width * 0.45
            let sweep = CAGradientLayer()
            sweep.frame = CGRect(x: 0, y: 0, width: band * 2, height: size.height)
            sweep.colors = [color.withAlphaComponent(0).cgColor, color.withAlphaComponent(0.22).cgColor, color.withAlphaComponent(0).cgColor]
            sweep.locations = [0, 0.5, 1]
            sweep.startPoint = CGPoint(x: 0, y: 0.3)
            sweep.endPoint = CGPoint(x: 1, y: 0.7)
            sweep.position = CGPoint(x: size.width + band, y: size.height / 2)
            let cycle = 2.6
            let move = CAKeyframeAnimation(keyPath: "position.x")
            move.values = [-band, size.width + band, size.width + band]
            move.keyTimes = [0, NSNumber(value: 1.6 / cycle), 1]
            layer.addSublayer(sweep)
            sweep.add(repeating(move, period: cycle, at: t), forKey: "sweep")

            // Sparkles drift right at 6pt a second and wrap, twinkling as
            // they go.
            let span = Double(size.width) + 10
            for s in sparkleSpots {
                let drift = CALayer()
                drift.position = CGPoint(x: -5, y: 4 + s.y * Double(size.height - 8))
                let star = CAShapeLayer()
                star.path = starPath(radius: s.size)
                star.fillColor = color.withAlphaComponent(0.85).cgColor
                star.contentsScale = scale
                star.opacity = 0
                drift.addSublayer(star)
                layer.addSublayer(drift)

                let across = CABasicAnimation(keyPath: "position.x")
                across.fromValue = -5
                across.toValue = span - 5
                across.timingFunction = CAMediaTimingFunction(name: .linear)
                let start = (s.x * Double(size.width)) / 6
                drift.add(repeating(across, period: span / 6, at: t + start), forKey: "drift")

                let period = 2 * Double.pi / s.speed
                let twinkle = { (time: Double) in max(0, sin(time * s.speed)) }
                let fade = sampled("opacity", period: period) { time in
                    let w = twinkle(time)
                    return w > 0.05 ? w * w : 0
                }
                let grow = sampled("transform.scale", period: period) { 0.6 + 0.4 * twinkle($0) }
                let both = CAAnimationGroup()
                both.animations = [fade, grow]
                star.add(repeating(both, period: period, at: t + s.phase / s.speed), forKey: "twinkle")
            }
        }

        private static func breathing(_ color: NSColor, from: Double, to: Double, period: Double, in layer: CALayer, size: CGSize) {
            let fill = CALayer()
            fill.frame = CGRect(origin: .zero, size: size)
            fill.backgroundColor = color.cgColor
            fill.opacity = Float(from)
            layer.addSublayer(fill)
            fill.add(repeating(sampled("opacity", period: period) { from + (to - from) * (0.5 - 0.5 * cos($0 / period * 2 * .pi)) },
                               period: period, at: now), forKey: "breath")
        }

        /// The glow behind a start page: brightest at the center, gone by
        /// `reach`, and a little brighter every four seconds.
        private static func glow(_ color: NSColor, center: CGPoint, reach: CGFloat, in layer: CALayer, size: CGSize) {
            let radius = max(size.width, size.height) * reach
            let gradient = CAGradientLayer()
            gradient.type = .radial
            gradient.frame = CGRect(x: center.x * size.width - radius, y: center.y * size.height - radius,
                                    width: radius * 2, height: radius * 2)
            gradient.colors = [color.withAlphaComponent(0.20).cgColor, color.withAlphaComponent(0).cgColor]
            gradient.locations = [0, 1]
            gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
            gradient.endPoint = CGPoint(x: 1, y: 1)
            gradient.opacity = 0.65
            layer.addSublayer(gradient)
            gradient.add(repeating(sampled("opacity", period: 8) { 0.65 + 0.35 * (0.5 - 0.5 * cos($0 / 8 * 2 * .pi)) },
                                   period: 8, at: now), forKey: "breath")
        }

        private static func arc(_ color: NSColor, lineWidth: CGFloat, in layer: CALayer, size: CGSize, scale: CGFloat) {
            let side = min(size.width, size.height)
            let ring = CAShapeLayer()
            ring.frame = CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side)
            ring.path = CGPath(ellipseIn: CGRect(origin: .zero, size: CGSize(width: side, height: side)).insetBy(dx: lineWidth / 2, dy: lineWidth / 2), transform: nil)
            ring.fillColor = nil
            ring.strokeColor = color.cgColor
            ring.lineWidth = lineWidth
            ring.lineCap = .round
            ring.strokeStart = 0.15
            ring.strokeEnd = 0.85
            ring.contentsScale = scale
            layer.addSublayer(ring)
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = 0
            turn.toValue = 2 * Double.pi
            turn.timingFunction = CAMediaTimingFunction(name: .linear)
            ring.add(repeating(turn, period: 1, at: now), forKey: "turn")
        }

        private static func blink(_ color: NSColor, period: Double, in layer: CALayer, size: CGSize) {
            let block = CALayer()
            block.frame = CGRect(origin: .zero, size: size)
            block.backgroundColor = color.cgColor
            layer.addSublayer(block)
            let flip = CAKeyframeAnimation(keyPath: "opacity")
            flip.values = [1, 0]
            flip.keyTimes = [0, 0.5]
            flip.calculationMode = .discrete
            block.add(repeating(flip, period: period, at: now), forKey: "blink")
        }

        static let glyphFrames = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"].map { $0 + "\u{FE0E}" }

        private static func glyphs(_ color: NSColor, glyphSize: CGFloat, in layer: CALayer, size: CGSize, scale: CGFloat) {
            // Drawn on a canvas twice the mark's size, since the symbols run
            // a little bigger than it.
            let canvas = CGSize(width: glyphSize * 2, height: glyphSize * 2)
            let images = glyphFrames.compactMap { glyphImage($0, color: color, glyphSize: glyphSize, canvas: canvas, scale: scale) }
            let glyph = CALayer()
            glyph.frame = CGRect(x: (size.width - canvas.width) / 2, y: (size.height - canvas.height) / 2,
                                 width: canvas.width, height: canvas.height)
            glyph.contentsScale = scale
            guard images.count == glyphFrames.count else { return }
            glyph.contents = images[4]
            layer.addSublayer(glyph)
            let flip = CAKeyframeAnimation(keyPath: "contents")
            flip.values = images
            flip.keyTimes = (0..<images.count).map { NSNumber(value: Double($0) / Double(images.count)) }
            flip.calculationMode = .discrete
            glyph.add(repeating(flip, period: 0.2 * Double(images.count), at: now), forKey: "spin")
        }

        private static func pulse(_ color: NSColor, dot: CGFloat, ring: CGFloat, ringTo: CGFloat,
                                  opacity: CGFloat, opacityTo: CGFloat, period: Double,
                                  in layer: CALayer, size: CGSize, scale: CGFloat) {
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let halo = CAShapeLayer()
            halo.path = CGPath(ellipseIn: CGRect(x: -ring / 2, y: -ring / 2, width: ring, height: ring), transform: nil)
            halo.fillColor = color.cgColor
            halo.contentsScale = scale
            halo.position = center
            halo.opacity = Float(opacity)
            layer.addSublayer(halo)

            let core = CAShapeLayer()
            core.path = CGPath(ellipseIn: CGRect(x: -dot / 2, y: -dot / 2, width: dot, height: dot), transform: nil)
            core.fillColor = color.cgColor
            core.contentsScale = scale
            core.position = center
            layer.addSublayer(core)

            let wave = { (time: Double) in 0.5 - 0.5 * cos(time / period * 2 * .pi) }
            let grow = sampled("transform.scale", period: period) { 1 + (Double(ringTo / ring) - 1) * wave($0) }
            let fade = sampled("opacity", period: period) { Double(opacity) + Double(opacityTo - opacity) * wave($0) }
            let both = CAAnimationGroup()
            both.animations = [grow, fade]
            halo.add(repeating(both, period: period, at: now), forKey: "pulse")
        }

        // MARK: Helpers

        private static var now: Double { Date().timeIntervalSinceReferenceDate }

        /// As fast as any of this motion needs to be drawn. Left alone, a
        /// ProMotion display plays it at 120 frames a second, and the
        /// window server redraws the window that often for as long as an
        /// agent works. These are slow, soft movements that look the same
        /// at 30.
        private static let frameRate = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)

        /// Repeats forever, starting partway through as if it had been
        /// running since the wall clock's zero.
        private static func repeating(_ animation: CAAnimation, period: Double, at time: Double) -> CAAnimation {
            animation.preferredFrameRateRange = frameRate
            animation.duration = period
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            animation.beginTime = CACurrentMediaTime()
            let into = time.truncatingRemainder(dividingBy: period)
            animation.timeOffset = into < 0 ? into + period : into
            return animation
        }

        /// A smooth curve as keyframes, from a function of the time into
        /// the cycle.
        private static func sampled(_ keyPath: String, period: Double, steps: Int = 32,
                                    _ value: (Double) -> Double) -> CAKeyframeAnimation {
            let animation = CAKeyframeAnimation(keyPath: keyPath)
            animation.values = (0...steps).map { value(Double($0) / Double(steps) * period) }
            animation.keyTimes = (0...steps).map { NSNumber(value: Double($0) / Double(steps)) }
            animation.duration = period
            return animation
        }

        private static func starPath(radius r: CGFloat) -> CGPath {
            let p = CGMutablePath()
            let c = CGPoint.zero
            p.move(to: CGPoint(x: 0, y: -r))
            p.addQuadCurve(to: CGPoint(x: r, y: 0), control: c)
            p.addQuadCurve(to: CGPoint(x: 0, y: r), control: c)
            p.addQuadCurve(to: CGPoint(x: -r, y: 0), control: c)
            p.addQuadCurve(to: CGPoint(x: 0, y: -r), control: c)
            return p
        }

        private static func glyphImage(_ text: String, color: NSColor, glyphSize: CGFloat,
                                       canvas: CGSize, scale: CGFloat) -> CGImage? {
            let pixels = (Int(canvas.width * scale), Int(canvas.height * scale))
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels.0, pixelsHigh: pixels.1,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
            rep.size = canvas
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            let string = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: glyphSize * 1.15, weight: .semibold),
                .foregroundColor: color,
            ])
            let bounds = string.size()
            string.draw(at: NSPoint(x: (canvas.width - bounds.width) / 2, y: (canvas.height - bounds.height) / 2))
            NSGraphicsContext.restoreGraphicsState()
            return rep.cgImage
        }
    }
}
#endif
