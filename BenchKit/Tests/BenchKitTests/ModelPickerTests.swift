import Testing
@testable import BenchKit

@Suite struct ModelPickerTests {
    @Test func plainModelCommandOpensThePicker() {
        #expect(ModelChoice.opensPicker("/model"))
        #expect(ModelChoice.opensPicker("  /model "))
        #expect(ModelChoice.opensPicker("/Model"))
        #expect(!ModelChoice.opensPicker("/model opus"))
        #expect(!ModelChoice.opensPicker("/models"))
        #expect(!ModelChoice.opensPicker("switch to /model"))
    }

    @Test func everyModelSaysWhatItsFor() {
        #expect(ModelChoice.all.allSatisfy { !$0.summary.isEmpty })
    }

    /// Only Fable is flagged, whether it's the session's model or the one
    /// being switched to.
    @Test func onlyFableIsFlaggedAsUsingLimitsFaster() {
        #expect(ModelChoice.all.filter(\.usesLimitsFaster).map(\.alias) == ["fable"])
        #expect(ModelChoice.usesLimitsFaster("Fable 5.1"))
        #expect(!ModelChoice.usesLimitsFaster("Opus 5.5"))
        #expect(!ModelChoice.usesLimitsFaster(nil))
        let fable = ModelChoice.all.first { $0.alias == "fable" }
        let opus = ModelChoice.all.first { $0.alias == "opus" }
        #expect(ModelChoice.usesLimitsFaster(model: "Opus 5.5", switching: fable))
        #expect(!ModelChoice.usesLimitsFaster(model: "Fable 5.1", switching: opus))
        #expect(ModelChoice.usesLimitsFaster(model: "Fable 5.1", switching: nil))
    }
}

@Suite struct EffortLevelTests {
    @Test func readsTheEffortCommand() {
        #expect(EffortLevel(command: "/effort high") == .high)
        #expect(EffortLevel(command: " /effort XHIGH ") == .xhigh)
        #expect(EffortLevel(command: "/effort") == nil)
        #expect(EffortLevel(command: "/effort huge") == nil)
        #expect(EffortLevel.max.command == "/effort max")
    }

    @Test func stepsStopAtTheEnds() {
        #expect(EffortLevel.high.stepped(1) == .xhigh)
        #expect(EffortLevel.max.stepped(1) == .max)
        #expect(EffortLevel.low.stepped(-1) == .low)
    }

    @Test func sameRequestTwiceIsStillAChange() {
        #expect(ModelRequest(effort: .high) != ModelRequest(effort: .high))
    }
}
