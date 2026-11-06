import Foundation

@main struct TabletAudioPolicyTests {
    static func main() {
        precondition(TabletAudioRoute.isTabletOutput(uid: "DualScreenAudio_UID"),
                     "Native tablet driver must route audio to the tablet")
        precondition(TabletAudioRoute.isTabletOutput(uid: "com.dualscreen.audio.xiaoxin-tb371fc"))
        precondition(!TabletAudioRoute.isTabletOutput(uid: "BuiltInSpeakerDevice"))
        precondition(!TabletAudioRoute.isTabletOutput(uid: "BlackHole2ch_UID"))
        print("PASS native and legacy route selection")
        precondition(TabletAudioRoute.amplitude(scalar: 0, decibels: -64, muted: false) == 0)
        precondition(TabletAudioRoute.amplitude(scalar: 1, decibels: 0, muted: false) == 1)
        precondition(TabletAudioRoute.amplitude(scalar: 1, decibels: 0, muted: true) == 0)
        precondition(abs(TabletAudioRoute.amplitude(scalar: 0.5, decibels: -32, muted: false) - 0.0251189) < 0.00001)
        precondition(TabletAudioRoute.amplitude(scalar: .nan, decibels: nil, muted: false) == 0)
        print("PASS volume endpoints, mute and driver dB curve")
        var samples: [Int16] = [12000, -12000, .max, .min, 123]
        TabletAudioRoute.scale(&samples, count: 4, gain: 0.5)
        precondition(samples == [6000, -6000, 16383, -16384, 123])
        TabletAudioRoute.scale(&samples, count: 4, gain: 0)
        precondition(samples == [0, 0, 0, 0, 123])
        print("PASS PCM attenuation and zero-volume silence")
    }
}
