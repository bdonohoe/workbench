import AVFoundation
import FluidAudio
import Foundation
import os

/// On-device transcription with NVIDIA's Parakeet TDT model, through
/// FluidAudio's Core ML port. Records the whole utterance and decodes it
/// in one go at stop(): Parakeet decodes far faster than realtime on Apple
/// Silicon, and seeing the full utterance gives it better punctuation.
///
/// Taken from Dict, which shares the model files on disk
/// (~/Library/Application Support/FluidAudio), so a Mac with Dict set up
/// has nothing to download.
@Observable
final class ParakeetEngine {
    /// How loud the microphone is right now, 0...1, for the composer's
    /// level bars. 0 while idle.
    private(set) var level: Float = 0
    private(set) var isRecording = false
    @ObservationIgnored var onProgress: ((Double) -> Void)?

    private nonisolated static let modelVersion = AsrModelVersion.v3
    static let sampleRate = 16_000
    /// Silence added to both ends of the recording before decoding. The
    /// recording starts and stops abruptly at the key, and Parakeet drops
    /// or garbles words that sit right at a hard edge.
    static let edgePaddingSeconds = 0.2

    private var manager: AsrManager?
    private var isPreparing = false
    /// Bumped by cancel() and stop() so a start() still waiting on the
    /// model or the microphone knows its session is already over.
    private var session = 0
    private let capture = AudioCapture()
    /// Token of the capture this recording started; see AudioCapture.stop.
    private var captureGeneration: Int?
    /// Recorded 16 kHz mono samples, appended from the realtime tap thread.
    /// Behind a lock rather than hopped to the main actor, so stop() can't
    /// lose buffers still in flight between actors.
    private let recordedSamples = OSAllocatedUnfairLock(initialState: [Float]())

    var isReady: Bool { manager != nil }

    /// Whether the model files are on disk. Checked against the folder
    /// each time, so a finished download shows up across relaunches.
    nonisolated static var isModelDownloaded: Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: modelVersion), version: modelVersion)
    }

    // MARK: - Model loading

    /// Downloads the model if it isn't on disk, then loads it. Safe to
    /// call again: it does nothing once the model is loaded.
    func prepare() async throws {
        guard manager == nil, !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }

        DictationLog.engine.info("Downloading or loading the Parakeet model")
        let models = try await AsrModels.downloadAndLoad(
            version: Self.modelVersion,
            progressHandler: { [weak self] progress in
                let fraction = progress.fractionCompleted
                Task { @MainActor in self?.onProgress?(fraction) }
            }
        )
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
        DictationLog.engine.info("Parakeet model loaded")
    }

    /// Lets go of the loaded model, when dictation is turned off.
    func unload() {
        cancel()
        manager = nil
    }

    // MARK: - Recording

    func start(deviceID: AudioDeviceID?) async throws {
        let startedSession = session
        try await prepare()
        guard manager != nil else { throw ParakeetEngineError.modelNotLoaded }
        // Cancelled or stopped while the model was loading: don't start a
        // recording nobody will stop.
        guard session == startedSession, !isRecording else { return }

        recordedSamples.withLock { $0 = [] }
        level = 0

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(Self.sampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw ParakeetEngineError.audioFormatUnavailable
        }

        // The tap runs on a realtime audio thread: samples go in under the
        // lock, and the level hops to the main actor. Buffers are converted
        // from whatever format they arrive in, so AirPods dropping to
        // 24 kHz mid-recording just works.
        let tapConverter = TapConverter(targetFormat: targetFormat)
        let samplesBox = recordedSamples
        let generation = try await capture.start(deviceID: deviceID) { [weak self] buffer in
            let rms = Self.rmsLevel(buffer)
            Task { @MainActor [weak self] in
                guard let self, self.isRecording else { return }
                self.level = Self.normalizedLevel(rms: rms)
            }
            guard let converted = tapConverter.convert(buffer),
                  let channel = converted.floatChannelData?[0] else { return }
            let frames = Int(converted.frameLength)
            guard frames > 0 else { return }
            let samples = Array(UnsafeBufferPointer(start: channel, count: frames))
            samplesBox.withLock { $0.append(contentsOf: samples) }
        }
        // The key was released, or Escape pressed, while the microphone was
        // still opening (a second or more on Bluetooth). Nobody else will
        // stop this capture.
        guard session == startedSession else {
            await capture.stop(generation: generation, flushing: false)
            return
        }
        captureGeneration = generation
        isRecording = true
        DictationLog.engine.info("Recording started")
    }

    /// Stops and throws the recording away without transcribing it.
    func cancel() {
        session += 1
        guard isRecording else { return }
        isRecording = false
        let generation = captureGeneration
        Task { await capture.stop(generation: generation, flushing: false) }
        captureGeneration = nil
        recordedSamples.withLock { $0 = [] }
        level = 0
        DictationLog.engine.info("Recording cancelled")
    }

    /// Ends the recording and returns what was said, or "" for silence.
    /// - Parameter waitsForQuiet: keep listening until the speaker goes
    ///   quiet. People let go of the key while still finishing a sentence.
    func stop(waitsForQuiet: Bool) async throws -> String {
        session += 1
        guard isRecording, manager != nil else { return "" }
        // A cancel() during the wait empties the buffer, so this returns "".
        if waitsForQuiet { await waitForReleaseTail() }
        isRecording = false
        await capture.stop(generation: captureGeneration)
        captureGeneration = nil
        level = 0

        let samples = recordedSamples.withLock { samples in
            let taken = samples
            samples = []
            return taken
        }
        let minimumSamples = ASRConstants.minimumRequiredSamples(forSampleRate: Self.sampleRate)
        guard samples.count >= minimumSamples else {
            DictationLog.engine.info("Recording too short (\(samples.count, privacy: .public) samples)")
            return ""
        }
        DictationLog.engine.notice("Recording stopped: \(String(format: "%.2f", Double(samples.count) / Double(Self.sampleRate)), privacy: .public)s of audio")
        return try await transcribe(samples)
    }

    /// Keeps recording until the audio after the release ends in a quiet
    /// stretch, or ReleaseTail.maximum has passed. Judged in recorded
    /// audio, not wall time: buffers arrive up to ~85 ms late, so a timer
    /// would count audio that hasn't shown up yet.
    private func waitForReleaseTail() async {
        let clock = ContinuousClock()
        let released = clock.now
        let releasedAt = recordedSamples.withLock { $0.count }
        while clock.now - released < ReleaseTail.maximum {
            try? await Task.sleep(for: ReleaseTail.pollInterval)
            let samples = recordedSamples.withLock { $0 }
            if samples.isEmpty { break }
            if ReleaseTail.endsQuietly(samples, releasedAt: releasedAt, sampleRate: Self.sampleRate) { break }
        }
        DictationLog.engine.info("Release tail: \(clock.now - released, privacy: .public)")
    }

    /// Decodes one whole recording with a fresh decoder state. Not private,
    /// so a test can drive the same path dictation uses.
    func transcribe(_ samples: [Float]) async throws -> String {
        guard let manager else { throw ParakeetEngineError.modelNotLoaded }
        let started = ProcessInfo.processInfo.systemUptime
        var decoderState = try TdtDecoderState(decoderLayers: await manager.decoderLayerCount)
        let padded = Self.padded(samples, seconds: Self.edgePaddingSeconds, sampleRate: Self.sampleRate)
        let result = try await manager.transcribe(padded, decoderState: &decoderState)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let timing = String(format: "decode=%.3fs audio=%.1fs chars=%d",
                            ProcessInfo.processInfo.systemUptime - started,
                            Float(samples.count) / Float(Self.sampleRate), text.count)
        DictationLog.engine.info("Parakeet \(timing, privacy: .public)")
        return text
    }

    // MARK: - Pure helpers

    /// Maps an RMS level onto 0...1 by loudness (decibels), not amplitude:
    /// a laptop microphone hears normal speech at an RMS of only 0.01 to
    /// 0.05, which a straight multiple leaves near the bottom. Room noise
    /// (-50 dB and under) stays at 0, quiet speech lands around a third,
    /// normal speech around a half to three quarters, and -15 dB tops out.
    nonisolated static func normalizedLevel(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(max((decibels + 50) / 35, 0), 1)
    }

    /// The recording with `seconds` of silence on each end.
    nonisolated static func padded(_ samples: [Float], seconds: Double, sampleRate: Int) -> [Float] {
        let silence = [Float](repeating: 0, count: Int(seconds * Double(sampleRate)))
        return silence + samples + silence
    }

    /// RMS of the first channel of a PCM buffer.
    nonisolated static func rmsLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count { let s = channel[i]; sum += s * s }
        return (sum / Float(count)).squareRoot()
    }
}

enum ParakeetEngineError: LocalizedError {
    case modelNotLoaded
    case audioFormatUnavailable

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: "The speech model didn't load."
        case .audioFormatUnavailable: "Couldn't set up the microphone's audio format."
        }
    }
}
