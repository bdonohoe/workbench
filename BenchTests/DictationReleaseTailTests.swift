import Foundation
import Testing
@testable import Bench

struct ReleaseTailTests {
    private let rate = 16_000

    private func noise(_ seconds: Double, level: Float) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { _ in Float.random(in: -level...level) }
    }

    /// A 200 Hz tone standing in for a voice.
    private func voice(_ seconds: Double, level: Float = 0.2) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { level * sin(2 * .pi * 200 * Float($0) / Float(rate)) }
    }

    private func endsQuietly(_ before: [Float], after: [Float]) -> Bool {
        ReleaseTail.endsQuietly(before + after, releasedAt: before.count, sampleRate: rate)
    }

    @Test func stillTalkingIsNotQuiet() {
        #expect(!endsQuietly(noise(0.5, level: 0.002) + voice(3), after: voice(0.5)))
    }

    @Test func aShortPauseIsNotYetQuiet() {
        #expect(!endsQuietly(voice(3), after: noise(0.25, level: 0.002)))
    }

    @Test func silenceAfterSpeechIsQuiet() {
        #expect(endsQuietly(noise(0.5, level: 0.002) + voice(3), after: noise(0.45, level: 0.002)))
    }

    /// The bug this guards: someone lets go while saying their last few
    /// words, and their voice drops. Soft speech is far above the floor.
    @Test func softFinalWordsAreNotQuiet() {
        let before = noise(0.5, level: 0.002) + voice(3, level: 0.2)
        let after = zip(voice(0.45, level: 0.03), noise(0.45, level: 0.002)).map(+)
        #expect(!endsQuietly(before, after: after))
    }

    /// Quiet before the release doesn't count: only audio recorded after
    /// the key came up can end the recording.
    @Test func quietBeforeReleaseIsNotEnough() {
        let before = noise(0.5, level: 0.002) + voice(3) + noise(0.4, level: 0.002)
        #expect(!endsQuietly(before, after: noise(0.2, level: 0.002)))
    }

    @Test func quietIsJudgedAgainstANoisyRoom() {
        let room = { self.noise($0, level: 0.03) }
        let before = room(1) + zip(voice(3), room(3)).map(+)
        #expect(endsQuietly(before, after: room(0.45)))
    }

    /// A room whose noise is a fifth of the voice and wavers from frame to
    /// frame, like a fan or a distant mic. Level is the average RMS.
    private func waveringRoom(_ seconds: Double, rms: Float = 0.002) -> [Float] {
        let gains: [Float] = [0.8, 1.0, 1.3, 0.9, 1.5, 1.0]
        let frame = rate / 50
        // Uniform noise of amplitude a has RMS a / √3; the gains average
        // 1.11 in RMS terms.
        let amplitude: Float = rms * 1.732 / 1.11
        return (0..<Int(seconds * Double(rate))).map { (i: Int) -> Float in
            let level: Float = amplitude * gains[(i / frame) % gains.count]
            return Float.random(in: -level...level)
        }
    }

    /// The bug this guards: the room's noise sat above the strict quiet
    /// threshold, so every dictation waited out the full maximum.
    @Test func roomNoiseCloseToVoiceLevelStillEnds() {
        let before = waveringRoom(1) + zip(voice(3, level: 0.014), waveringRoom(3)).map(+)
        #expect(endsQuietly(before, after: waveringRoom(0.45)))
    }

    @Test func softFinalWordsOverRoomNoiseAreNotQuiet() {
        let before = waveringRoom(1) + zip(voice(3, level: 0.014), waveringRoom(3)).map(+)
        let after = zip(voice(0.45, level: 0.007), waveringRoom(0.45)).map(+)
        #expect(!endsQuietly(before, after: after))
    }

    @Test func recordingWithNoSpeechDoesNotWait() {
        #expect(endsQuietly(noise(2, level: 0.002), after: noise(0.45, level: 0.002)))
    }

    @Test func tooLittleAudioAfterReleaseKeepsListening() {
        #expect(!endsQuietly(noise(2, level: 0.002), after: noise(0.1, level: 0.002)))
    }
}
