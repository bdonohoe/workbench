import AVFoundation
import Foundation
import Testing
@testable import Bench

/// Runs a recording through the real speech model and the cleanup, the
/// way a dictation goes. Only when BENCH_DICTATION_AUDIO names a 16 kHz
/// mono audio file, since it needs the Parakeet model on disk (about
/// 500 MB, downloaded if it's missing):
///
///     say -o /tmp/speech.wav --data-format=LEF32@16000 "merge into main"
///     TEST_RUNNER_BENCH_DICTATION_AUDIO=/tmp/speech.wav make test
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BENCH_DICTATION_AUDIO"] != nil))
struct DictationEndToEndTests {
    @Test func aRecordingComesOutAsText() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["BENCH_DICTATION_AUDIO"])
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        #expect(Int(file.processingFormat.sampleRate) == ParakeetEngine.sampleRate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try #require(buffer.floatChannelData?[0])
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))

        let engine = ParakeetEngine()
        try await engine.prepare()
        let raw = try await engine.transcribe(samples)
        #expect(raw.split(separator: " ").count >= 3)

        let withTerms = await DictationCleanup.clean(raw, fixingTerms: true)
        let rulesOnly = await DictationCleanup.clean(raw, fixingTerms: false)
        #expect(!withTerms.isEmpty)
        #expect(!rulesOnly.isEmpty)
        print("DICTATION raw: \(raw)")
        print("DICTATION rules only: \(rulesOnly)")
        print("DICTATION with terms (Apple Intelligence available: \(DictationCleanup.canFixTerms)): \(withTerms)")
    }
}
