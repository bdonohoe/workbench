import Foundation

/// The color a project's icon is mostly made of, for lighting the project's
/// start page in its own color. Works on plain pixels so it can be tested
/// without an image.
public enum IconTint {
    public struct RGB: Equatable, Sendable {
        public var red: Double
        public var green: Double
        public var blue: Double

        public init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    /// The dominant color of `rgba` (8 bits each of red, green, blue and
    /// alpha per pixel, not premultiplied), or nil when the icon is mostly
    /// grey, black or white and has no color to speak of.
    ///
    /// Pixels vote for their hue, weighted by how colorful and how opaque
    /// they are, so a white glyph on a purple tile says purple, and a thin
    /// colored outline on a grey icon says nothing.
    public static func dominant(rgba: [UInt8]) -> RGB? {
        let count = rgba.count / 4
        guard count > 0 else { return nil }
        let bins = 24
        var weight = [Double](repeating: 0, count: bins)
        var sums = [(r: Double, g: Double, b: Double)](repeating: (0, 0, 0), count: bins)
        var opaque = 0.0
        for index in 0..<count {
            let alpha = Double(rgba[index * 4 + 3]) / 255
            guard alpha > 0.1 else { continue }
            let r = Double(rgba[index * 4]) / 255, g = Double(rgba[index * 4 + 1]) / 255, b = Double(rgba[index * 4 + 2]) / 255
            opaque += alpha
            let high = max(r, g, b), low = min(r, g, b)
            let chroma = high - low
            // Near-greys, and colors too dark to tell apart from black.
            guard chroma > 0.12, high > 0.2 else { continue }
            let bin = min(bins - 1, Int(hue(r, g, b, high: high, chroma: chroma) * Double(bins)))
            let vote = chroma * alpha
            weight[bin] += vote
            sums[bin].r += r * vote
            sums[bin].g += g * vote
            sums[bin].b += b * vote
        }
        guard opaque > 0 else { return nil }
        // A hue and the one next to it count together, since one color in a
        // gradient or a JPEG spreads across two bins.
        var best = 0, bestWeight = 0.0
        for bin in 0..<bins {
            let pair = weight[bin] + weight[(bin + 1) % bins]
            if pair > bestWeight { best = bin; bestWeight = pair }
        }
        // Colorful pixels have to cover a fair part of the icon.
        guard bestWeight / opaque > 0.04 else { return nil }
        let next = (best + 1) % bins
        let total = weight[best] + weight[next]
        return RGB(red: (sums[best].r + sums[next].r) / total,
                   green: (sums[best].g + sums[next].g) / total,
                   blue: (sums[best].b + sums[next].b) / total)
    }

    /// 0 to 1 around the color wheel.
    private static func hue(_ r: Double, _ g: Double, _ b: Double, high: Double, chroma: Double) -> Double {
        var hue: Double
        if high == r {
            hue = ((g - b) / chroma).truncatingRemainder(dividingBy: 6)
        } else if high == g {
            hue = (b - r) / chroma + 2
        } else {
            hue = (r - g) / chroma + 4
        }
        hue /= 6
        return hue < 0 ? hue + 1 : hue
    }

    /// The hue (0 to 1) of the lettered tile a project gets when it has no
    /// icon, from its repo's name. Swift's own hash changes between
    /// launches, so this is a small fixed one.
    public static func tileHue(for repoName: String) -> Double {
        var hash = 5381
        for byte in repoName.lowercased().utf8 { hash = (hash &* 33) &+ Int(byte) }
        return Double(abs(hash) % 360) / 360
    }
}
