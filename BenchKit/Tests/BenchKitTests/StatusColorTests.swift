import Testing
@testable import BenchKit

struct StatusColorTests {
    /// Near-black, like a dark panel.
    private let darkPanel = RGB.gray(0.11)

    @Test func everyStatusReadsOnLightAndDark() {
        for (name, pair) in StatusColors.all {
            let onWhite = StatusColors.contrast(pair.light, on: .white)
            let onDark = StatusColors.contrast(pair.dark, on: darkPanel)
            #expect(onWhite >= 4.5, "\(name) light value is \(onWhite) on white")
            #expect(onDark >= 4.5, "\(name) dark value is \(onDark) on a dark panel")
        }
    }

    @Test func contrastMatchesTheDefinition() {
        #expect(abs(StatusColors.contrast(.black, on: .white) - 21) < 0.01)
        #expect(abs(StatusColors.contrast(.white, on: .white) - 1) < 0.001)
        // Symmetric.
        let a = RGB(hex: 0x1A7F37)
        #expect(StatusColors.contrast(a, on: .white) == StatusColors.contrast(.white, on: a))
    }

    @Test func hexSplitsIntoParts() {
        let c = RGB(hex: 0xFF8000)
        #expect(c.red == 1)
        #expect(abs(c.green - 128.0 / 255) < 0.0001)
        #expect(c.blue == 0)
    }
}
