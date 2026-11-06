import Foundation
import CoreAudio

// Compile with Sources/DualScreenHost/TabletAudioRoute.swift.
// Temporarily switches the default output; always restores it afterwards.
@main struct AudioRouteRegression {
    static func main() throws {
        assert(TabletAudioRoute.isTabletOutput(uid: TabletAudioRoute.deviceUID))
        assert(!TabletAudioRoute.isTabletOutput(uid: "BuiltInSpeakerDevice"))
        assert(!TabletAudioRoute.isTabletOutput(uid: "BlackHole2ch_UID"))
        var property = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var original: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        precondition(AudioObjectGetPropertyData(system, &property, 0, nil, &size, &original) == noErr)
        defer { var restore = original; _ = AudioObjectSetPropertyData(system, &property, 0, nil, size, &restore) }
        var listProperty = property
        listProperty.mSelector = kAudioHardwarePropertyDevices
        var listSize: UInt32 = 0
        precondition(AudioObjectGetPropertyDataSize(system, &listProperty, 0, nil, &listSize) == noErr)
        var devices = [AudioObjectID](repeating: 0, count: Int(listSize) / MemoryLayout<AudioObjectID>.size)
        precondition(AudioObjectGetPropertyData(system, &listProperty, 0, nil, &listSize, &devices) == noErr)
        var tested = 0
        for device in devices {
            var uidProperty = property
            uidProperty.mSelector = kAudioDevicePropertyDeviceUID
            var uid: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(device, &uidProperty, 0, nil, &uidSize, &uid) == noErr,
                  let uid else { continue }
            let name = uid.takeUnretainedValue() as String
            guard TabletAudioRoute.isTabletOutput(uid: name) || name == "BuiltInSpeakerDevice" else { continue }
            var selected = device
            precondition(AudioObjectSetPropertyData(system, &property, 0, nil, size, &selected) == noErr)
            Thread.sleep(forTimeInterval: 0.3)
            let expected = TabletAudioRoute.isTabletOutput(uid: name)
            precondition(TabletAudioRoute().shouldForward() == expected)
            print("PASS \(name): forwarding=\(expected)")
            tested += 1
        }
        precondition(tested >= 2, "Need both tablet and built-in speaker devices")
    }
}
