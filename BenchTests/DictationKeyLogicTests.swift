import Testing
@testable import Bench

/// What the dictation key does: hold to talk, a quick tap is nothing,
/// Space goes hands-free, Escape or another key throws the recording away.
struct DictationKeyLogicTests {
    private let clock = ContinuousClock()

    @Test func holdingStartsAndReleasingStops() {
        var logic = DictationKeyLogic()
        let down = clock.now
        #expect(logic.keyDown(now: down) == .start)
        #expect(logic.keyUp(now: down + .milliseconds(600)) == .stop)
        #expect(!logic.isRecording)
    }

    @Test func aQuickTapIsThrownAway() {
        var logic = DictationKeyLogic()
        let down = clock.now
        #expect(logic.keyDown(now: down) == .start)
        #expect(logic.keyUp(now: down + .milliseconds(80)) == .cancel)
    }

    @Test func repeatedDownEventsDoNothing() {
        var logic = DictationKeyLogic()
        #expect(logic.keyDown() == .start)
        #expect(logic.keyDown() == nil)
    }

    @Test func spaceWhileHoldingGoesHandsFree() {
        var logic = DictationKeyLogic()
        let down = clock.now
        _ = logic.keyDown(now: down)
        #expect(logic.swallowsSpace)
        #expect(logic.spaceDown() == .enterHandsFree)
        // Letting go keeps listening, and Space types again.
        #expect(logic.keyUp(now: down + .seconds(1)) == nil)
        #expect(logic.isRecording)
        #expect(!logic.swallowsSpace)
        #expect(logic.spaceDown() == nil)
        // The next press finishes, and its release does nothing more.
        #expect(logic.keyDown() == .stop)
        #expect(logic.keyUp() == nil)
        #expect(!logic.isRecording)
    }

    @Test func spaceWithoutTheKeyIsJustSpace() {
        var logic = DictationKeyLogic()
        #expect(!logic.swallowsSpace)
        #expect(logic.spaceDown() == nil)
    }

    @Test func escapeCancelsHeldAndHandsFree() {
        var logic = DictationKeyLogic()
        #expect(logic.escapeDown() == nil)
        _ = logic.keyDown()
        #expect(logic.escapeDown() == .cancel)
        #expect(logic.keyUp() == nil)

        _ = logic.keyDown()
        _ = logic.spaceDown()
        _ = logic.keyUp()
        #expect(logic.escapeDown() == .cancel)
        #expect(!logic.isRecording)
    }

    @Test func anotherKeyMeansItWasAShortcut() {
        var logic = DictationKeyLogic()
        _ = logic.keyDown()
        #expect(logic.otherKeyDown() == .cancel)
        #expect(logic.keyUp() == nil)
        // Typing during a hands-free recording doesn't end it.
        _ = logic.keyDown()
        _ = logic.spaceDown()
        _ = logic.keyUp()
        #expect(logic.otherKeyDown() == nil)
        #expect(logic.isRecording)
    }

    @Test func theKeyFinishesARecordingTheButtonStarted() {
        var logic = DictationKeyLogic()
        logic.beganHandsFree()
        #expect(logic.keyDown() == .stop)
        #expect(!logic.isRecording)
    }

    @Test func aRefusedStartIsForgotten() {
        var logic = DictationKeyLogic()
        _ = logic.keyDown()
        logic.reset()
        #expect(logic.keyUp() == nil)
        #expect(logic.keyDown() == .start)
    }
}
