import Foundation
import CoreAudio

/// Used only on the serial audio capture queue. Fail closed on lookup errors.
final class TabletAudioRoute {
    static let deviceUID = "com.dualscreen.audio.xiaoxin-tb371fc"
    static let nativeDeviceUID = "DualScreenAudio_UID"
    private var lastCheck = Date.distantPast
    private var enabled = false
    private(set) var gain: Float = 0

    static func scale(_ samples: inout [Int16], count: Int, gain: Float) {
        let safeGain = gain.isFinite ? min(1, max(0, gain)) : 0
        guard safeGain < 1 else { return }
        for index in 0..<max(0, min(count, samples.count)) {
            samples[index] = Int16(Float(samples[index]) * safeGain)
        }
    }

    /// SCK captures before device gain: apply the selected device's volume
    /// once to streamed PCM. Use its dB curve rather than a linear UI scalar.
    static func amplitude(scalar: Float, decibels: Float?, muted: Bool) -> Float {
        guard !muted, scalar.isFinite, scalar > 0 else { return 0 }
        if let decibels, decibels.isFinite {
            return min(1, max(0, pow(10, decibels / 20)))
        }
        return min(1, scalar)
    }

    private func outputValue<T>(_ device: AudioObjectID,
                                _ selector: AudioObjectPropertySelector,
                                initial: T) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        return status == noErr ? value : nil
    }

    static func isTabletOutput(uid: String) -> Bool {
        uid == deviceUID || uid == nativeDeviceUID
    }

    func shouldForward() -> Bool {
        let now = Date()
        guard now.timeIntervalSince(lastCheck) >= 0.1 else { return enabled }
        lastCheck = now
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var selected = false
        var selectedUID = ""
        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                      0, nil, &size, &device) == noErr {
            address.mSelector = kAudioDevicePropertyDeviceUID
            var uid: Unmanaged<CFString>?
            size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr,
               let uid {
                selectedUID = uid.takeUnretainedValue() as String
                selected = Self.isTabletOutput(uid: selectedUID)
            }
        }
        if selected != enabled {
            print("[audio] tablet routing \(selected ? "enabled" : "disabled")")
        }
        enabled = selected
        if selectedUID == Self.nativeDeviceUID {
            let scalar: Float = outputValue(device, kAudioDevicePropertyVolumeScalar, initial: Float(0)) ?? 0
            let decibels: Float? = outputValue(device, kAudioDevicePropertyVolumeDecibels, initial: Float(0))
            let mute: UInt32 = outputValue(device, kAudioDevicePropertyMute, initial: UInt32(0)) ?? 0
            gain = Self.amplitude(scalar: scalar, decibels: decibels, muted: mute != 0)
        } else {
            gain = selected ? 1 : 0
        }
        return enabled
    }
}
