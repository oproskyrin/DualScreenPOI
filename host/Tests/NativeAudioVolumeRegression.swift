import Foundation
import CoreAudio

// Standalone integration test: compile with TabletAudioRoute.swift.
// Exercises the real HAL output control and the stream gain, restoring settings.
@main struct NativeAudioVolumeRegression {
    static func main() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var property = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        precondition(AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size) == noErr)
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        precondition(AudioObjectGetPropertyData(system, &property, 0, nil, &size, &devices) == noErr)
        let tablet = devices.first { device in
            var uidProperty = property
            uidProperty.mSelector = kAudioDevicePropertyDeviceUID
            var uid: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            return AudioObjectGetPropertyData(device, &uidProperty, 0, nil, &uidSize, &uid) == noErr
                && uid?.takeUnretainedValue() as String? == TabletAudioRoute.nativeDeviceUID
        }
        guard var tablet else {
            fputs("FAIL native tablet audio driver is not installed\n", stderr)
            exit(1)
        }
        property.mSelector = kAudioHardwarePropertyDefaultOutputDevice
        size = UInt32(MemoryLayout<AudioObjectID>.size)
        var original: AudioObjectID = 0
        precondition(AudioObjectGetPropertyData(system, &property, 0, nil, &size, &original) == noErr)
        precondition(AudioObjectSetPropertyData(system, &property, 0, nil, size, &tablet) == noErr)
        defer { _ = AudioObjectSetPropertyData(system, &property, 0, nil, size, &original) }
        var volume = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var settable = DarwinBoolean(false)
        precondition(AudioObjectIsPropertySettable(tablet, &volume, &settable) == noErr && settable.boolValue,
                     "Native system volume slider must be writable")
        var originalVolume: Float = 0
        var volumeSize = UInt32(MemoryLayout<Float>.size)
        precondition(AudioObjectGetPropertyData(tablet, &volume, 0, nil, &volumeSize, &originalVolume) == noErr)
        defer { _ = AudioObjectSetPropertyData(tablet, &volume, 0, nil, volumeSize, &originalVolume) }
        let route = TabletAudioRoute()
        for scalar: Float in [0, 0.5, 1] {
            var value = scalar
            precondition(AudioObjectSetPropertyData(tablet, &volume, 0, nil, volumeSize, &value) == noErr)
            Thread.sleep(forTimeInterval: 0.25)
            precondition(route.shouldForward())
            let expected = scalar == 0 ? 0 : pow(10, (scalar * 64 - 64) / 20)
            precondition(abs(route.gain - expected) < 0.0001, "Wrong stream volume gain")
            print("PASS native slider=\(scalar), PCM gain=\(route.gain)")
        }
        var mute = volume
        mute.mSelector = kAudioDevicePropertyMute
        var muted: UInt32 = 0
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        precondition(AudioObjectGetPropertyData(tablet, &mute, 0, nil, &muteSize, &muted) == noErr)
        defer { _ = AudioObjectSetPropertyData(tablet, &mute, 0, nil, muteSize, &muted) }
        var yes: UInt32 = 1
        precondition(AudioObjectSetPropertyData(tablet, &mute, 0, nil, muteSize, &yes) == noErr)
        Thread.sleep(forTimeInterval: 0.25)
        precondition(route.shouldForward() && route.gain == 0)
        print("PASS native mute yields zero PCM gain")
    }
}
