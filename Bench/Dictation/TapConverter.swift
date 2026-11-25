import AVFoundation

/// Converts mic buffers to a fixed target format, building its
/// AVAudioConverter from whatever format the buffers actually arrive in.
///
/// Selecting AirPods as the mic drops them into a 24 kHz call mode, and
/// capture reopens at the new rate. Reading the format off each buffer keeps
/// the conversion right even if the device changes mid-recording.
///
/// Only touched from AudioCapture's tap, which never runs concurrently,
/// so the mutable state needs no lock.
nonisolated final class TapConverter: @unchecked Sendable {
    let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    init(targetFormat: AVAudioFormat) {
        self.targetFormat = targetFormat
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if sourceFormat != buffer.format {
            sourceFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
        }
        guard let converter else { return nil }
        return Self.convert(buffer, using: converter, to: targetFormat)
    }

    /// Sample-rate-aware conversion of one buffer.
    static func convert(_ buffer: AVAudioPCMBuffer,
                        using converter: AVAudioConverter,
                        to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        return err == nil ? out : nil
    }
}
