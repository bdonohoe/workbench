import Testing
@testable import BenchKit

struct MotionLevelTests {
    /// The raw values are saved in settings, so changing one would quietly
    /// put people back on Full.
    @Test func savedValuesStayTheSame() {
        #expect(MotionLevel.allCases.map(\.rawValue) == ["full", "calm", "still"])
        #expect(MotionLevel.key == "motionLevel")
    }
}
