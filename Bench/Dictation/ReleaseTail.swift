import Foundation

/// Decides when to stop recording after the hotkey is released. People
/// often let go while still finishing a sentence, and their voice tends to
/// drop on those last words. So the mic stays on until the audio recorded
/// *after* the release has a stretch that sits down at the room's noise
/// floor. Soft speech is well above the floor, so it keeps the mic open.
///
/// Two tests can end the recording. The strict one wants every frame of
/// the stretch near the floor, which a quiet room passes. A room whose
/// noise is a fifth of the voice (a fan, a distant mic) never passes it,
/// so the second test compares the stretch's average level with the noise
/// measured in this recording.
nonisolated enum ReleaseTail {
    /// Never keep more than this, so steady background noise can't hold
    /// the recording open.
    static let maximum: Duration = .milliseconds(3000)
    /// How often to check whether the speaker has gone quiet.
    static let pollInterval: Duration = .milliseconds(50)
    /// How long the speaker must be quiet, after release, before the
    /// recording ends. Also the least audio kept after release.
    static let quietSeconds = 0.4

    /// Audio is judged in frames this long.
    static let frameSeconds = 0.02

    /// Below this the recording held no clear speech, so there is nothing
    /// to wait for.
    static let noSpeechLevel: Float = 0.005

    /// How far from the noise floor toward speech level a frame may sit
    /// and still count as quiet. Kept low so trailing, softly spoken words
    /// don't pass for silence.
    static let quietFraction: Float = 0.05

    /// How far above the measured room noise the average level of the
    /// last `quietSeconds` may sit and still count as quiet. Steady noise
    /// averages 1.2 to 1.5 times its own tenth percentile; a soft word on
    /// top of it pushes the average past this.
    static let noiseMargin: Float = 1.6

    /// The measured noise is never taken to be more than this share of
    /// speech level, for a recording with no pause to measure it in.
    static let noiseCeiling: Float = 0.3

    struct Levels: Equatable {
        var floor: Float
        var speech: Float
        /// Every frame of the tail under this: quiet.
        var threshold: Float
        /// Average level of the tail under this: quiet.
        var roomThreshold: Float
    }

    /// Noise floor, speech level and quiet threshold of a recording.
    static func levels(_ samples: [Float], sampleRate: Int) -> Levels? {
        let frameLength = Int(frameSeconds * Double(sampleRate))
        guard frameLength > 0, samples.count >= frameLength else { return nil }
        let sorted = frameLevels(samples, frameLength: frameLength).sorted()
        let speech = sorted[min(sorted.count - 1, sorted.count * 95 / 100)]
        // Capped so a recording that is speech from start to finish, with
        // no quiet stretch to measure, still gets a sensible floor.
        let measured = sorted[sorted.count / 10]
        let floor = min(measured, speech * 0.1)
        return Levels(
            floor: floor,
            speech: speech,
            threshold: floor + (speech - floor) * quietFraction,
            roomThreshold: min(measured, speech * noiseCeiling) * noiseMargin
        )
    }

    /// Whether the recording can stop: at least `quietSeconds` of audio has
    /// arrived since the release (sample index `releasedAt`) and the last
    /// `quietSeconds` of it sit near the noise floor, frame by frame or on
    /// average.
    static func endsQuietly(_ samples: [Float], releasedAt: Int, sampleRate: Int) -> Bool {
        let frameLength = Int(frameSeconds * Double(sampleRate))
        let quietFrames = Int((quietSeconds / frameSeconds).rounded())
        let afterRelease = samples.count - max(0, releasedAt)
        guard frameLength > 0, afterRelease >= frameLength * quietFrames,
              let levels = levels(samples, sampleRate: sampleRate) else { return false }
        guard levels.speech > noSpeechLevel else { return true }
        let tail = frameLevels(Array(samples.suffix(frameLength * quietFrames)), frameLength: frameLength)
        if tail.allSatisfy({ $0 < levels.threshold }) { return true }
        let average = (tail.reduce(0) { $0 + $1 * $1 } / Float(tail.count)).squareRoot()
        return average < levels.roomThreshold
    }

    /// RMS level of each whole frame.
    static func frameLevels(_ samples: [Float], frameLength: Int) -> [Float] {
        stride(from: 0, to: samples.count - frameLength + 1, by: frameLength).map { start in
            var sum: Float = 0
            for i in start..<(start + frameLength) { sum += samples[i] * samples[i] }
            return (sum / Float(frameLength)).squareRoot()
        }
    }
}
