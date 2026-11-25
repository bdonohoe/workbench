import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import os

/// The microphone side of a recording: an input-only audio unit that exists
/// only while recording, and the restart when the input reconfigures.
///
/// This deliberately doesn't use AVAudioEngine. Touching an engine's
/// inputNode makes CoreAudio build a hidden aggregate of the default input
/// and output devices, and that aggregate stays until the app quits, even
/// after the engine is gone. With Bluetooth headphones it can hold them in
/// their low-quality call mode while nothing is being recorded.
///
/// It's an actor so opening the device runs off the main actor. A Bluetooth
/// headset blocks those calls for a second or more while it switches its
/// mic on; on the main actor that froze the HUD.
actor AudioCapture {
    typealias Tap = @Sendable (AVAudioPCMBuffer) -> Void

    private var unit: InputUnit?
    private var tap: Tap?
    private var deviceID: AudioDeviceID?
    private var rateListener: (device: AudioDeviceID, block: AudioObjectPropertyListenerBlock)?
    private let listenerQueue = DispatchQueue(label: "me.birchtree.Bench.dictation.input-rate")
    /// Restarts so far this capture. Capped so a device that keeps
    /// reconfiguring can't loop forever.
    private var restarts = 0
    private static let maxRestarts = 3
    /// True while a restart is waiting on the hardware, so the watchdog
    /// and a sample rate change don't start a second one.
    private var restarting = false
    /// Bumped by every start(). stop(generation:) only stops a capture
    /// that is still the one the caller started.
    private var generation = 0
    private(set) var isCapturing = false
    /// When the unit last delivered audio. The watchdog restarts the
    /// capture if that stops: a Bluetooth input can change format without
    /// warning, and the unit then just goes quiet.
    private let heartbeat = Heartbeat()
    private var watchdog: Task<Void, Never>?
    /// Audio normally arrives at least every 85 ms, so this is several
    /// missed callbacks.
    static let stallThreshold: Duration = .milliseconds(600)

    private static let maxStartRetries = 3
    private static let startRetryDelay: Duration = .milliseconds(200)

    /// Starts recording from `deviceID` (nil uses the system default) and
    /// feeds mono buffers to `tap` on the realtime audio thread. Returns a
    /// generation token for stop(generation:).
    @discardableResult
    func start(deviceID: AudioDeviceID?, tap: @escaping Tap) async throws -> Int {
        if isCapturing { stop() }
        generation += 1
        let generation = generation
        let clock = ContinuousClock()
        let started = clock.now
        self.deviceID = deviceID
        self.tap = tap
        restarts = 0
        do {
            try await openUnit(generation: generation)
        } catch {
            if generation == self.generation { self.tap = nil }
            throw error
        }
        guard generation == self.generation, self.tap != nil else {
            // A stop() or newer start() came in while we waited on the
            // hardware; that one owns the capture now.
            if generation == self.generation { closeUnit(flushing: false) }
            throw CancellationError()
        }
        isCapturing = true
        heartbeat.beat()
        startWatchdog()
        let elapsed = clock.now - started
        let description = unit.map { Self.describe($0.format) } ?? "no format"
        DictationLog.engine.info("Capture started in \(elapsed, privacy: .public) on device \(deviceID.map(String.init) ?? "default", privacy: .public) at \(description, privacy: .public)")
        return generation
    }

    /// Stops the capture if it is still generation `generation` (or any,
    /// when nil), and releases the microphone. A start that was outpaced by
    /// the key release uses the token so it can't stop a newer recording.
    /// - Parameter flushing: deliver the audio still waiting in the last
    ///   partial buffer. False when the recording is being thrown away.
    func stop(generation: Int? = nil, flushing: Bool = true) {
        if let generation, generation != self.generation { return }
        tap = nil
        isCapturing = false
        watchdog?.cancel()
        watchdog = nil
        closeUnit(flushing: flushing)
    }

    /// Opens and starts a unit on the current device. Opening a Bluetooth
    /// mic can fail while it changes mode, so this retries a few times.
    private func openUnit(generation: Int) async throws {
        var lastError: any Error = AudioCaptureError.noInput
        for attempt in 0...Self.maxStartRetries {
            if attempt > 0 { try await Task.sleep(for: Self.startRetryDelay) }
            // stop() clears the tap; if that happened while waiting on the
            // hardware, don't bring the microphone up.
            guard generation == self.generation, let tap else { throw CancellationError() }
            guard let device = deviceID ?? AudioInputDevices.systemDefault()?.id else {
                throw AudioCaptureError.noInput
            }
            do {
                let opened = try InputUnit(deviceID: device, heartbeat: heartbeat, onBuffer: tap)
                do {
                    try opened.start()
                } catch {
                    opened.close(flushing: false)
                    throw error
                }
                unit = opened
                listenForRateChanges(on: device)
                return
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func closeUnit(flushing: Bool) {
        stopListeningForRateChanges()
        unit?.close(flushing: flushing)
        unit = nil
    }

    /// AirPods drop from 48 kHz to 24 kHz as their mic opens. An input unit
    /// can't resample, so it has to be reopened at the new rate.
    private func listenForRateChanges(on device: AudioDeviceID) {
        stopListeningForRateChanges()
        var address = AudioInputDevices.nominalSampleRateAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { [weak self] in await self?.sampleRateChanged() }
        }
        guard AudioObjectAddPropertyListenerBlock(device, &address, listenerQueue, block) == noErr else { return }
        rateListener = (device, block)
    }

    private func stopListeningForRateChanges() {
        guard let rateListener else { return }
        var address = AudioInputDevices.nominalSampleRateAddress
        AudioObjectRemovePropertyListenerBlock(rateListener.device, &address, listenerQueue, rateListener.block)
        self.rateListener = nil
    }

    private func sampleRateChanged() async {
        guard let unit, let rate = AudioInputDevices.nominalSampleRate(of: unit.deviceID),
              rate != unit.format.sampleRate else { return }
        await restart(reason: "sample rate changed to \(Int(rate)) Hz")
    }

    private func startWatchdog() {
        watchdog?.cancel()
        let generation = generation
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, !Task.isCancelled else { return }
                await self.restartIfStalled(generation: generation)
            }
        }
    }

    private func restartIfStalled(generation: Int) async {
        guard isCapturing, self.generation == generation, !restarting else { return }
        let silence = heartbeat.age()
        guard silence > Self.stallThreshold else { return }
        await restart(reason: "no audio for \(silence)")
    }

    /// Closes the unit and opens a new one on the current hardware format.
    /// Capped at `maxRestarts` per capture.
    private func restart(reason: String) async {
        guard isCapturing, tap != nil, restarts < Self.maxRestarts, !restarting else { return }
        restarts += 1
        restarting = true
        defer { restarting = false }
        let generation = generation
        closeUnit(flushing: true)
        do {
            try await openUnit(generation: generation)
            guard generation == self.generation else { return }
            heartbeat.beat()
            let description = unit.map { Self.describe($0.format) } ?? "no format"
            DictationLog.engine.info("Capture restarted (\(reason, privacy: .public)) at \(description, privacy: .public)")
        } catch {
            guard generation == self.generation, !(error is CancellationError) else { return }
            DictationLog.engine.error("Couldn't restart capture (\(reason, privacy: .public)): \(String(describing: error), privacy: .public)")
            // The device may still be mid-transition; try again shortly.
            // Keep the heartbeat fresh so the watchdog waits its turn.
            heartbeat.beat()
            Task {
                try? await Task.sleep(for: .milliseconds(200))
                guard self.generation == generation else { return }
                await self.restart(reason: reason)
            }
        }
    }

    nonisolated static func describe(_ format: AVAudioFormat) -> String {
        "\(format.channelCount) ch \(Int(format.sampleRate)) Hz"
    }
}

/// One AUHAL unit with input on and output off, bound directly to a device
/// so CoreAudio builds no default-device aggregate. Collects the small
/// hardware callbacks into 4096-frame mono buffers.
///
/// `render` runs on the realtime thread. `close` stops the unit first, which
/// waits for any callback in progress, so the buffers are never shared.
nonisolated final class InputUnit: @unchecked Sendable {
    static let chunkFrames: AVAudioFrameCount = 4096

    let deviceID: AudioDeviceID
    let format: AVAudioFormat
    private let unit: AudioUnit
    private let scratch: AVAudioPCMBuffer
    private let chunk: AVAudioPCMBuffer
    private let heartbeat: Heartbeat
    private let onBuffer: AudioCapture.Tap
    private var isClosed = false

    init(deviceID: AudioDeviceID, heartbeat: Heartbeat, onBuffer: @escaping AudioCapture.Tap) throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else { throw AudioCaptureError.noInput }
        var created: AudioUnit?
        try Self.check(AudioComponentInstanceNew(component, &created))
        guard let unit = created else { throw AudioCaptureError.noInput }

        do {
            let (format, maxFrames) = try Self.configure(unit, deviceID: deviceID)
            guard let scratch = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maxFrames),
                  let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.chunkFrames) else {
                throw AudioCaptureError.noInput
            }
            self.deviceID = deviceID
            self.format = format
            self.unit = unit
            self.scratch = scratch
            self.chunk = chunk
            self.heartbeat = heartbeat
            self.onBuffer = onBuffer
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }

        do {
            var callback = AURenderCallbackStruct(
                inputProc: { refCon, flags, timestamp, bus, frames, _ in
                    Unmanaged<InputUnit>.fromOpaque(refCon).takeUnretainedValue()
                        .render(flags: flags, timestamp: timestamp, bus: bus, frames: frames)
                },
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
            )
            try Self.check(AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            ))
            try Self.check(AudioUnitInitialize(unit))
        } catch {
            isClosed = true
            AudioComponentInstanceDispose(unit)
            throw error
        }
    }

    /// Turns input on, picks the device, and asks for mono Float32 at the
    /// device's own rate. Returns that format and the largest callback.
    private static func configure(_ unit: AudioUnit, deviceID: AudioDeviceID) throws -> (AVAudioFormat, AVAudioFrameCount) {
        let inputBus: AudioUnitElement = 1
        let outputBus: AudioUnitElement = 0
        let size32 = UInt32(MemoryLayout<UInt32>.size)
        var on: UInt32 = 1
        var off: UInt32 = 0
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, inputBus, &on, size32))
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, outputBus, &off, size32))
        var device = deviceID
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size)))

        var hardware = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, inputBus, &hardware, &size))
        guard hardware.mSampleRate > 0, hardware.mChannelsPerFrame > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hardware.mSampleRate, channels: 1, interleaved: false)
        else { throw AudioCaptureError.noInput }

        var client = format.streamDescription.pointee
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, inputBus, &client, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))
        // Record the device's first channel.
        var channelMap: [Int32] = [0]
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output, inputBus, &channelMap, UInt32(MemoryLayout<Int32>.size)))

        var maxFrames: UInt32 = 0
        var maxSize = size32
        try check(AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, &maxSize))
        return (format, max(maxFrames, chunkFrames))
    }

    func start() throws {
        try Self.check(AudioOutputUnitStart(unit))
    }

    /// Stops the unit and gives the device back. Safe to call twice.
    func close(flushing: Bool) {
        guard !isClosed else { return }
        isClosed = true
        AudioOutputUnitStop(unit)
        if flushing, chunk.frameLength > 0 { onBuffer(chunk) }
        chunk.frameLength = 0
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }

    private func render(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        bus: UInt32,
        frames: UInt32
    ) -> OSStatus {
        guard frames <= scratch.frameCapacity else { return kAudio_ParamError }
        let buffers = UnsafeMutableAudioBufferListPointer(scratch.mutableAudioBufferList)
        buffers[0].mDataByteSize = frames * UInt32(MemoryLayout<Float>.size)
        let status = AudioUnitRender(unit, flags, timestamp, bus, frames, scratch.mutableAudioBufferList)
        guard status == noErr, let source = scratch.floatChannelData?[0],
              let destination = chunk.floatChannelData?[0] else { return status }
        heartbeat.beat()

        var copied: UInt32 = 0
        while copied < frames {
            let filled = chunk.frameLength
            let count = min(frames - copied, Self.chunkFrames - filled)
            (destination + Int(filled)).update(from: source + Int(copied), count: Int(count))
            chunk.frameLength = filled + count
            copied += count
            if chunk.frameLength == Self.chunkFrames {
                onBuffer(chunk)
                chunk.frameLength = 0
            }
        }
        return noErr
    }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw AudioCaptureError.unit(status) }
    }
}

/// A timestamp the realtime audio thread bumps and the actor reads.
nonisolated final class Heartbeat: Sendable {
    private let last = OSAllocatedUnfairLock(initialState: ContinuousClock.now)

    func beat() { last.withLock { $0 = .now } }

    func age() -> Duration { last.withLock { ContinuousClock.now - $0 } }
}

nonisolated enum AudioCaptureError: LocalizedError {
    /// No usable input format: no microphone, or no microphone permission.
    case noInput
    /// CoreAudio refused a step of opening the microphone.
    case unit(OSStatus)

    var errorDescription: String? {
        switch self {
        case .noInput: "No microphone is available."
        case .unit(let status): "The microphone couldn't be opened (\(status))."
        }
    }
}
