import BenchKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Smaller copies of the pictures in a conversation, for the wire to a
/// phone, and the whole pictures kept for when the phone asks for one.
///
/// A screenshot in a transcript is often a megabyte or two, and a long
/// conversation has dozens. The phone shows each at most 320 points tall,
/// so a copy no longer than 1024 pixels on its long side looks the same
/// there. As HEIC it's about a fifth of the PNG's size; as JPEG, which
/// does badly on screenshots full of text, it would be about half.
/// NSCache is thread-safe, so this needn't be on any actor.
nonisolated final class ImagePreviews: @unchecked Sendable {
    static let shared = ImagePreviews()

    /// The long side of a preview, in pixels.
    static let previewPixels = 1024
    /// A picture already smaller than this goes as it is.
    static let smallEnough = 160 << 10

    /// Whole pictures by id, for `full(id:)`. Costed by bytes.
    private let wholes = NSCache<NSString, Boxed>()
    /// Finished previews by id, so a reconnect doesn't make them again.
    private let previews = NSCache<NSString, Boxed>()

    private final class Boxed: @unchecked Sendable {
        let image: TranscriptImage
        init(_ image: TranscriptImage) { self.image = image }
    }

    private init() {
        // A whole picture not here is read back from its transcript when
        // the phone opens it; keeping 160 MB of them around for that was
        // most of the app's memory after a day of screenshots.
        wholes.totalCostLimit = 32 << 20
        previews.totalCostLimit = 48 << 20
    }

    /// The messages with each picture replaced by its preview. Work runs
    /// off the caller's thread, one picture at a time per core.
    func shrink(_ messages: [TranscriptMessage]) async -> [TranscriptMessage] {
        guard messages.contains(where: { $0.images.contains { !$0.isPreview } }) else { return messages }
        return await Task.detached(priority: .userInitiated) { [self] in
            var result = messages
            await withTaskGroup(of: (Int, Int, TranscriptImage).self) { group in
                for (m, message) in messages.enumerated() {
                    for (i, image) in message.images.enumerated() {
                        group.addTask { (m, i, self.preview(of: image)) }
                    }
                }
                for await (m, i, image) in group { result[m].images[i] = image }
            }
            return result
        }.value
    }

    /// Like `shrink`, on the caller's thread, for the streamer's queue:
    /// a conversation's pictures become previews as they're read, so no
    /// list of messages holds the whole ones.
    func shrinkNow(_ messages: inout [TranscriptMessage]) {
        var spots: [(message: Int, image: Int)] = []
        for (m, message) in messages.enumerated() {
            for i in message.images.indices where !message.images[i].isPreview { spots.append((m, i)) }
        }
        guard !spots.isEmpty else { return }
        let source = messages
        var made = [TranscriptImage?](repeating: nil, count: spots.count)
        made.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: spots.count) { n in
                buffer[n] = preview(of: source[spots[n].message].images[spots[n].image])
            }
        }
        for (n, spot) in spots.enumerated() {
            if let image = made[n] { messages[spot.message].images[spot.image] = image }
        }
    }

    /// A picture's preview, made now if it hasn't been. Keeps the whole
    /// picture for `full(id:)` either way.
    func preview(of image: TranscriptImage) -> TranscriptImage {
        if image.isPreview { return image }
        if let done = previews.object(forKey: image.id as NSString) { return done.image }
        let made = Self.shrink(image)
        if !image.isPreview {
            // With the size the preview worked out, so the whole one has it too.
            var whole = image
            whole.width = made.width
            whole.height = made.height
            wholes.setObject(Boxed(whole), forKey: image.id as NSString, cost: whole.data.count)
        }
        previews.setObject(Boxed(made), forKey: image.id as NSString, cost: made.data.count)
        return made
    }

    /// The whole picture, from what went through here or, failing that,
    /// read again from one of the transcripts given.
    func full(id: String, transcriptPaths: [String]) async -> TranscriptImage? {
        if let whole = wholes.object(forKey: id as NSString) { return whole.image }
        return await Task.detached(priority: .userInitiated) { [self] in
            for path in transcriptPaths {
                if let found = Self.find(id: id, in: path) {
                    wholes.setObject(Boxed(found), forKey: id as NSString, cost: found.data.count)
                    return found
                }
            }
            return nil
        }.value
    }

    // MARK: Making previews

    private static func shrink(_ image: TranscriptImage) -> TranscriptImage {
        guard let source = CGImageSourceCreateWithData(image.data as CFData, nil) else { return image }
        var result = image
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int
        let height = properties?[kCGImagePropertyPixelHeight] as? Int
        result.width = width
        result.height = height
        let longest = max(width ?? 0, height ?? 0)
        if image.data.count <= smallEnough, longest <= previewPixels * 2 { return result }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: previewPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let encoded = heic(thumbnail) else { return result }
        // Only worth it when the copy is meaningfully smaller.
        guard encoded.count < image.data.count * 3 / 4 else { return result }
        result.data = encoded
        result.mediaType = "image/heic"
        result.isPreview = true
        return result
    }

    private static func heic(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    // MARK: Reading a picture back

    /// Reads the transcript line the picture came from. Image ids start
    /// with the line's uuid, which the file holds exactly once.
    private static func find(id: String, in path: String) -> TranscriptImage? {
        guard let uuid = id.split(separator: "/").first, uuid.count >= 8,
              let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let needle = Data(uuid.utf8)
        let format = Agents.transcripts(for: path).format
        var carry = Data()
        while let chunk = try? handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            var data = carry + chunk
            // Finish at a line end, and keep the rest for the next round.
            if let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) {
                carry = Data(data[data.index(after: lastNewline)...])
                data = Data(data[...lastNewline])
            } else {
                carry = data
                continue
            }
            guard data.range(of: needle) != nil else { continue }
            for line in data.split(separator: UInt8(ascii: "\n")) where line.range(of: needle) != nil {
                let messages = format.messages(in: Data(line), options: .init(keepsResults: true))
                if let found = messages.lazy.flatMap(\.images).first(where: { $0.id == id }) { return found }
            }
        }
        if carry.range(of: needle) != nil {
            let messages = format.messages(in: carry, options: .init(keepsResults: true))
            return messages.lazy.flatMap(\.images).first { $0.id == id }
        }
        return nil
    }
}
