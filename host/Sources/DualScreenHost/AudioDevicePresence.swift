import Foundation
import Darwin
import notify
import CoreAudio

/// A narrow routing adapter keeps regression tests free of actual HAL writes.
struct AudioPresenceRouting {
    var defaultUID: () -> String?
    var availableUIDs: () -> [String]
    var builtInUID: () -> String?
    var setDefaultUID: (String) -> Bool

    static var system: AudioPresenceRouting {
        AudioPresenceRouting(
            defaultUID: { NativePresenceRouting.defaultUID() },
            availableUIDs: { NativePresenceRouting.outputs().map { $0.uid } },
            builtInUID: { NativePresenceRouting.outputs().first { $0.builtIn }?.uid },
            setDefaultUID: { NativePresenceRouting.select($0) })
    }
}

private enum NativePresenceRouting {
    struct Output { let id: AudioDeviceID; let uid: String; let builtIn: Bool }
    static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        _ value: inout T, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var a = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0) == noErr
        }
    }
    static func uid(_ id: AudioDeviceID) -> String? {
        var value: Unmanaged<CFString>?
        guard read(id, kAudioDevicePropertyDeviceUID, &value) else { return nil }
        return value?.takeUnretainedValue() as String?
    }
    static func defaultUID() -> String? {
        var device = AudioDeviceID(0)
        guard read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, &device) else { return nil }
        return uid(device)
    }
    static func outputs() -> [Output] {
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var alive: UInt32 = 0
            var transport: UInt32 = 0
            guard read(id, kAudioDevicePropertyDeviceIsAlive, &alive), alive != 0,
                  let uid = uid(id) else { return nil }
            // Require at least one output stream, not merely an input device.
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var streamBytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamBytes) == noErr, streamBytes > 0 else { return nil }
            var canDefault: UInt32 = 0
            guard read(id, kAudioDevicePropertyDeviceCanBeDefaultDevice, &canDefault, scope: kAudioObjectPropertyScopeOutput), canDefault != 0 else { return nil }
            _ = read(id, kAudioDevicePropertyTransportType, &transport)
            return Output(id: id, uid: uid, builtIn: transport == kAudioDeviceTransportTypeBuiltIn)
        }
    }
    static func select(_ target: String) -> Bool {
        // Recheck the current selection immediately before any write. Don't
        // override a route chosen by the user (or CoreAudio) during shutdown.
        guard AudioDevicePresence.isTablet(defaultUID()),
              let output = outputs().first(where: { $0.uid == target }),
              !AudioDevicePresence.isTablet(output.uid) else { return false }
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = output.id
        guard AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil,
            UInt32(MemoryLayout.size(ofValue: id)), &id) == noErr else { return false }
        return defaultUID() == target
    }
}


/// Publishes availability only for the real, successfully started Mac server.
/// Own one instance for the runtime lifetime; do not start in updater/smoke modes.
/// Darwin notify is a public, machine-wide hint, not an authentication channel.
final class AudioDevicePresence {
    static let notificationName = "com.oleg.dualscreen.host.audio-pid"
    private let name: String
    private let lock = NSLock()
    private var pidToken: Int32 = -1
    private var birthToken: Int32 = -1
    private var heartbeatToken: Int32 = -1
    private var ownBirth: UInt64 = 0
    private var timer: DispatchSourceTimer?
    private var generation: UInt64 = 0
    private var active = false
    private let routing: AudioPresenceRouting
    private var previousUID: String?

    static func isTablet(_ uid: String?) -> Bool {
        uid == "DualScreenAudio_UID" || uid == "com.dualscreen.audio.xiaoxin-tb371fc"
    }

    init(notificationName: String = AudioDevicePresence.notificationName,
         routing: AudioPresenceRouting = .system) {
        name = notificationName
        self.routing = routing
    }

    @discardableResult
    func start() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if active { return true }
        guard notify_register_check(name, &pidToken) == NOTIFY_STATUS_OK else { return false }
        guard notify_register_check(name + ".start-time", &birthToken) == NOTIFY_STATUS_OK,
              notify_register_check(name + ".heartbeat", &heartbeatToken) == NOTIFY_STATUS_OK else {
            cancelTokens()
            return false
        }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, size) == size else {
            cancelTokens()
            return false
        }
        let birth = info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
        // Snapshot the route before making the device available.
        let current = routing.defaultUID()
        previousUID = Self.isTablet(current) ? nil : current
        // Publish identity before the PID; PID zero is always inactive.
        guard notify_set_state(birthToken, birth) == NOTIFY_STATUS_OK,
              notify_set_state(pidToken, UInt64(getpid())) == NOTIFY_STATUS_OK else {
            cancelTokens()
            return false
        }
        ownBirth = birth
        guard notify_set_state(heartbeatToken, mach_continuous_time()) == NOTIFY_STATUS_OK else {
            if ownsPublication() { notify_set_state(pidToken, 0) }
            cancelTokens()
            return false
        }
        active = true
        generation &+= 1
        let startedGeneration = generation
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.dualscreen.host.audio-heartbeat"))
        source.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250), leeway: .milliseconds(25))
        source.setEventHandler { [weak self] in self?.publishHeartbeat(generation: startedGeneration) }
        timer = source
        source.resume()
        notify_post(name)
        return true
    }

    // The same lock serializes start, stop and timer callbacks. A generation
    // check also rejects already-enqueued callbacks from a prior start/stop.
    private func publishHeartbeat(generation expected: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard active, generation == expected, ownsPublication() else { return }
        notify_set_state(heartbeatToken, mach_continuous_time())
    }

    private func ownsPublication() -> Bool {
        var owner: UInt64 = 0, birth: UInt64 = 0
        return notify_get_state(pidToken, &owner) == NOTIFY_STATUS_OK && owner == UInt64(getpid()) &&
            notify_get_state(birthToken, &birth) == NOTIFY_STATUS_OK && birth == ownBirth
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return }
        active = false
        generation &+= 1
        timer?.cancel()
        timer = nil
        if ownsPublication() {
            // If the user already selected another output, leave it alone.
            // On a crash the HAL removes the device and CoreAudio owns fallback;
            // normal stop can additionally restore a still-valid previous route.
            if Self.isTablet(routing.defaultUID()) {
                let available = routing.availableUIDs().filter { !Self.isTablet($0) }
                let preferred = previousUID.flatMap { available.contains($0) ? $0 : nil }
                let builtIn = routing.builtInUID().flatMap { available.contains($0) ? $0 : nil }
                if let target = preferred ?? builtIn ?? available.first,
                   Self.isTablet(routing.defaultUID()) {
                    _ = routing.setDefaultUID(target)
                }
            }
            notify_set_state(heartbeatToken, 0)
            notify_set_state(pidToken, 0)
            notify_post(name)
        }
        active = false
        cancelTokens()
    }

    private func cancelTokens() {
        if pidToken >= 0 { notify_cancel(pidToken); pidToken = -1 }
        if birthToken >= 0 { notify_cancel(birthToken); birthToken = -1 }
        if heartbeatToken >= 0 { notify_cancel(heartbeatToken); heartbeatToken = -1 }
    }

    deinit { stop() }
}
