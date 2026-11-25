import Testing
@testable import BenchKit

struct IconTintTests {
    private func pixels(_ colors: [(UInt8, UInt8, UInt8, UInt8)]) -> [UInt8] {
        colors.flatMap { [$0.0, $0.1, $0.2, $0.3] }
    }

    @Test func aWhiteGlyphOnAPurpleTileIsPurple() throws {
        let purple: (UInt8, UInt8, UInt8, UInt8) = (120, 60, 200, 255)
        let white: (UInt8, UInt8, UInt8, UInt8) = (255, 255, 255, 255)
        let tint = try #require(IconTint.dominant(rgba: pixels(Array(repeating: purple, count: 70) + Array(repeating: white, count: 30))))
        #expect(tint.blue > tint.red && tint.red > tint.green)
    }

    @Test func aGreyIconHasNoTint() {
        let greys = (0..<100).map { step -> (UInt8, UInt8, UInt8, UInt8) in
            let value = UInt8(40 + step * 2)
            return (value, value, value, 255)
        }
        #expect(IconTint.dominant(rgba: pixels(greys)) == nil)
    }

    @Test func aSpeckOfColorOnGreyIsNotATint() {
        let grey: (UInt8, UInt8, UInt8, UInt8) = (90, 90, 90, 255)
        let red: (UInt8, UInt8, UInt8, UInt8) = (230, 40, 40, 255)
        #expect(IconTint.dominant(rgba: pixels(Array(repeating: grey, count: 99) + [red])) == nil)
    }

    @Test func theBiggerColorWins() throws {
        let orange: (UInt8, UInt8, UInt8, UInt8) = (240, 140, 30, 255)
        let blue: (UInt8, UInt8, UInt8, UInt8) = (40, 90, 230, 255)
        let tint = try #require(IconTint.dominant(rgba: pixels(Array(repeating: orange, count: 60) + Array(repeating: blue, count: 40))))
        #expect(tint.red > tint.blue)
    }

    @Test func clearPixelsDoNotVote() throws {
        let clearRed: (UInt8, UInt8, UInt8, UInt8) = (255, 0, 0, 0)
        let green: (UInt8, UInt8, UInt8, UInt8) = (40, 200, 90, 255)
        let tint = try #require(IconTint.dominant(rgba: pixels(Array(repeating: clearRed, count: 80) + Array(repeating: green, count: 20))))
        #expect(tint.green > tint.red)
    }

    @Test func nothingInIsNothingOut() {
        #expect(IconTint.dominant(rgba: []) == nil)
    }
}
