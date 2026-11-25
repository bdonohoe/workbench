import SwiftUI
#if canImport(UIKit)
import UIKit
public typealias PlatformImage = UIImage
#else
import AppKit
public typealias PlatformImage = NSImage
#endif

extension Image {
    public init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}

/// Decoded pictures, kept so scrolling doesn't decode them again.
@MainActor
public final class ImageCache {
    public static let shared = ImageCache()
    private let cache = NSCache<NSString, PlatformImage>()

    public func image(for image: TranscriptImage) -> PlatformImage? {
        decode(image.data, key: Self.key(for: image))
    }

    /// The picture if it has been decoded already, without decoding it.
    public func cached(_ image: TranscriptImage) -> PlatformImage? {
        cache.object(forKey: Self.key(for: image) as NSString)
    }

    /// The picture, decoded off the main thread if it hasn't been yet.
    public func load(_ image: TranscriptImage) async -> PlatformImage? {
        if let cached = cached(image) { return cached }
        let data = image.data
        #if canImport(UIKit)
        // Decoded and drawn into its own bitmap now, so the first frame
        // that shows it has nothing left to do.
        let decoded = await Task.detached(priority: .userInitiated) { UIImage(data: data)?.preparingForDisplay() }.value
        #else
        let decoded = NSImage(data: data)
        #endif
        guard let decoded else { return nil }
        cache.setObject(decoded, forKey: Self.key(for: image) as NSString)
        return decoded
    }

    /// A preview and the whole picture share an id.
    private static func key(for image: TranscriptImage) -> String {
        image.isPreview ? image.id + "/preview" : image.id
    }

    /// A project's sidebar icon, as the Mac sent it.
    public func icon(_ data: Data, for id: UUID) -> PlatformImage? {
        decode(data, key: "\(id.uuidString)/\(data.count)")
    }

    private func decode(_ data: Data, key: String) -> PlatformImage? {
        if let cached = cache.object(forKey: key as NSString) { return cached }
        guard let decoded = PlatformImage(data: data) else { return nil }
        cache.setObject(decoded, forKey: key as NSString)
        return decoded
    }
}
