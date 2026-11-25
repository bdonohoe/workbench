import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import BenchKit

/// A PNG of random-looking noise, which compresses badly, like the worst screenshot.
private func noisyPNG(width: Int, height: Int, alpha: UInt8 = 255) -> Data {
    var pixels = [UInt8](repeating: alpha, count: width * height * 4)
    var seed: UInt32 = 12345
    for index in stride(from: 0, to: pixels.count, by: 4) {
        for channel in 0..<3 {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            pixels[index + channel] = alpha == 0 ? 0 : UInt8(seed >> 24)
        }
    }
    let context = pixels.withUnsafeMutableBytes {
        CGContext(data: $0.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }
    let image = context.makeImage()!
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return output as Data
}

private func isJPEG(_ data: Data) -> Bool { data.starts(with: [0xFF, 0xD8, 0xFF]) }

@Test func makesAJPEGFromAPNG() throws {
    let jpeg = try #require(FeedbackScreenshot.prepare(noisyPNG(width: 200, height: 100)))
    #expect(isJPEG(jpeg))
}

@Test func bigPicturesFitTheLimit() throws {
    let jpeg = try #require(FeedbackScreenshot.prepare(noisyPNG(width: 3000, height: 2000)))
    #expect(isJPEG(jpeg))
    #expect(jpeg.count <= FeedbackScreenshot.maxBytes)
}

@Test func aFullSetAtTheLimitFitsOneRequest() {
    let base64 = (FeedbackScreenshot.maxBytes + 2) / 3 * 4
    #expect(base64 * FeedbackScreenshot.maxCount + 40_000 < 4_500_000)
}

@Test func transparencyBecomesWhite() throws {
    let jpeg = try #require(FeedbackScreenshot.prepare(noisyPNG(width: 40, height: 40, alpha: 0)))
    let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let bytes = try #require(image.dataProvider?.data as Data?)
    #expect(bytes[0] > 250)
}

@Test func notAPictureIsRefused() {
    #expect(FeedbackScreenshot.prepare(Data("hello".utf8)) == nil)
}
