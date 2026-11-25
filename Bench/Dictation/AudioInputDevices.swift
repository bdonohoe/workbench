import CoreAudio
import Foundation

/// A microphone CoreAudio knows about.
struct AudioInputDevice: Identifiable, Equatable {
    enum Transport: Equatable {
        case builtIn, bluetooth, usb, other
    }

    let id: AudioDeviceID
    /// Stable across reboots and reconnects, unlike `id`.
    let uid: String
    let name: String
    let transport: Transport
}

/// CoreAudio lookups for the microphones dictation can record from.
nonisolated enum AudioInputDevices {
    /// Every device with at least one input stream.
    static func all() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap(device(for:))
    }

    /// The device macOS currently routes input to.
    static func systemDefault() -> AudioInputDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr
        else { return nil }
        return device(for: deviceID)
    }

    static let nominalSampleRateAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    /// The rate `id` is running at, or nil if it can't be read.
    static func nominalSampleRate(of id: AudioDeviceID) -> Double? {
        var address = nominalSampleRateAddress
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate) == noErr, rate > 0 else { return nil }
        return rate
    }

    // MARK: - Property helpers

    private static func device(for id: AudioDeviceID) -> AudioInputDevice? {
        guard inputStreamCount(id) > 0,
              let uid = string(kAudioDevicePropertyDeviceUID, of: id),
              let name = string(kAudioDevicePropertyDeviceNameCFString, of: id) else { return nil }
        return AudioInputDevice(id: id, uid: uid, name: name, transport: transport(of: id))
    }

    private static func inputStreamCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    private static func transport(of id: AudioDeviceID) -> AudioInputDevice.Transport {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport) == noErr else { return .other }
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeUSB: return .usb
        default: return .other
        }
    }

    private static func string(_ selector: AudioObjectPropertySelector, of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

extension AudioInputDevices {
    /// The microphone dictation records from: the system default, except
    /// that a Bluetooth headset gives way to the built-in mic. Headsets
    /// record at phone quality and switch their output to call mode.
    static func automatic() -> AudioInputDevice? {
        automatic(devices: all(), systemDefault: systemDefault())
    }

    static func automatic(devices: [AudioInputDevice], systemDefault: AudioInputDevice?) -> AudioInputDevice? {
        guard let systemDefault else { return devices.first }
        if systemDefault.transport == .bluetooth,
           let builtIn = devices.first(where: { $0.transport == .builtIn }) {
            return builtIn
        }
        return systemDefault
    }
}
