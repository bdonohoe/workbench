import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Shrinks a picture for the feedback form, small enough to fit in one
/// request to the relay, which allows about 4.5 MB in all.
public enum FeedbackScreenshot {
    public static let maxCount = 4
    public static let maxBytes = 800_000

    /// Sharpest first. Most screenshots fit on the first step, and text stays
    /// readable until the last few, which are for very busy pictures.
    private static let steps: [(edge: Int, quality: Double)] = [
        (2000, 0.7), (1600, 0.65), (1200, 0.6), (1000, 0.5), (800, 0.4),
    ]

    /// A JPEG of the picture, or nil if it can't be read or won't fit.
    public static func prepare(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        for step in steps {
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: step.edge,
            ] as CFDictionary), let flat = flattened(image), let jpeg = jpeg(flat, quality: step.quality),
                jpeg.count <= maxBytes else { continue }
            return jpeg
        }
        return nil
    }

    /// On white, since JPEG has no transparency and a window screenshot's
    /// see-through shadow would otherwise turn black.
    private static func flattened(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(bounds)
        context.draw(image, in: bounds)
        return context.makeImage()
    }

    private static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
