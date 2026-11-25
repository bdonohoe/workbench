import Foundation
import Testing
@testable import BenchKit

/// Which path the client keeps: Tailscale when it answers, the home
/// network when it doesn't.
@Suite struct ConnectionRaceTests {
    @Test func tailscaleOnlyNeverStartsLocal() {
        let race = ConnectionRace(hasTailscale: true, hasLocal: false)
        #expect(!race.startsLocal(at: 0))
        #expect(!race.startsLocal(at: 100))
    }

    @Test func localOnlyStartsLocalAtZero() {
        let race = ConnectionRace(hasTailscale: false, hasLocal: true)
        #expect(race.startsLocal(at: 0))
    }

    @Test func localStartsAfterHeadStart() {
        let race = ConnectionRace(hasTailscale: true, hasLocal: true)
        #expect(!race.startsLocal(at: 1.0))
        #expect(race.startsLocal(at: 1.5))
    }

    @Test func tailscaleWinsAsSoonAsItAnswers() {
        var race = ConnectionRace(hasTailscale: true, hasLocal: true)
        #expect(race.welcomed(.tailscale, at: 0.4) == .tailscale)
    }

    @Test func tailscaleBeatsLocalInsideHold() {
        var race = ConnectionRace(hasTailscale: true, hasLocal: true)
        #expect(race.welcomed(.local, at: 2.0) == nil)
        #expect(race.tick(at: 2.1) == nil)
        #expect(race.welcomed(.tailscale, at: 2.2) == .tailscale)
    }

    @Test func localWinsAfterHold() {
        var race = ConnectionRace(hasTailscale: true, hasLocal: true)
        #expect(race.welcomed(.local, at: 2.0) == nil)
        #expect(race.tick(at: 2.31) == .local)
    }

    @Test func localWinsAtOnceWithoutTailscale() {
        var race = ConnectionRace(hasTailscale: false, hasLocal: true)
        #expect(race.welcomed(.local, at: 0.5) == .local)
    }

    @Test func localWinsAtOnceWhenTailscaleFailed() {
        var race = ConnectionRace(hasTailscale: true, hasLocal: true)
        let ended = race.failed(.tailscale)
        #expect(!ended)
        #expect(race.startsLocal(at: 0.2))
        #expect(race.welcomed(.local, at: 0.5) == .local)
    }

    @Test func bothFailedEndsTheRace() {
        var race = ConnectionRace(hasTailscale: true, hasLocal: true)
        let localFailed = race.failed(.local)
        #expect(!localFailed)
        let bothFailed = race.failed(.tailscale)
        #expect(bothFailed)

        var localOnly = ConnectionRace(hasTailscale: false, hasLocal: true)
        let localOnlyFailed = localOnly.failed(.local)
        #expect(localOnlyFailed)
    }

    @Test func localGivesUpAtTimeout() {
        let race = ConnectionRace(hasTailscale: true, hasLocal: true)
        #expect(race.startsLocal(at: 1.5 + 8))
        #expect(!race.localTimedOut(at: 1.5 + 7.9))
        #expect(race.localTimedOut(at: 1.5 + 8))

        let localOnly = ConnectionRace(hasTailscale: false, hasLocal: true)
        #expect(!localOnly.localTimedOut(at: 7.9))
        #expect(localOnly.localTimedOut(at: 8))
    }

    /// The clock matters while the home network has yet to start, time out
    /// or sit out its hold. Once it has failed, only Tailscale's own answer
    /// or failure is left, and nothing needs polling.
    @Test func theClockStopsMatteringOnceLocalHasFailed() {
        var race = ConnectionRace(hasTailscale: true, hasLocal: true)
        #expect(race.waitsOnClock)
        _ = race.welcomed(.local, at: 2)
        #expect(race.waitsOnClock)
        _ = race.tick(at: 2.5)
        #expect(!race.waitsOnClock)

        var failed = ConnectionRace(hasTailscale: true, hasLocal: true)
        _ = failed.failed(.local)
        #expect(!failed.waitsOnClock)

        var tailscaleFirst = ConnectionRace(hasTailscale: true, hasLocal: true)
        _ = tailscaleFirst.failed(.tailscale)
        #expect(tailscaleFirst.waitsOnClock)

        let tailscaleOnly = ConnectionRace(hasTailscale: true, hasLocal: false)
        #expect(!tailscaleOnly.waitsOnClock)
    }
}
