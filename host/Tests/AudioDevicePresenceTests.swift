import Foundation
import Darwin
import notify

@main
struct AudioDevicePresenceTests {
    static func main() {
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--publisher" {
            let name = CommandLine.arguments[2]
            precondition(name.hasPrefix("com.oleg.dualscreen.test."))
            let noRoutes = AudioPresenceRouting(defaultUID: { nil }, availableUIDs: { [] },
                builtInUID: { nil }, setDefaultUID: { _ in preconditionFailure("unexpected route write") })
            let presence = AudioDevicePresence(notificationName: name, routing: noRoutes)
            precondition(presence.start())
            signal(SIGTERM, SIG_IGN)
            let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: DispatchQueue.global())
            termination.setEventHandler { presence.stop(); exit(0) }
            termination.resume()
            withExtendedLifetime((presence, termination)) { while true { pause() } }
            return
        }
        let name = "com.oleg.dualscreen.test.host-presence.\(UUID().uuidString)"
        var token: Int32 = -1
        precondition(notify_register_check(name, &token) == NOTIFY_STATUS_OK)
        defer { notify_set_state(token, 0); notify_cancel(token) }
        func state() -> UInt64 {
            var value: UInt64 = 0
            precondition(notify_get_state(token, &value) == NOTIFY_STATUS_OK)
            return value
        }
        let noRoutes = AudioPresenceRouting(defaultUID: { nil }, availableUIDs: { [] },
            builtInUID: { nil }, setDefaultUID: { _ in preconditionFailure("unexpected route write") })
        var heartbeatToken: Int32 = -1
        precondition(notify_register_check(name + ".heartbeat", &heartbeatToken) == NOTIFY_STATUS_OK)
        defer { notify_cancel(heartbeatToken) }
        func heartbeat() -> UInt64 {
            var value: UInt64 = 0
            precondition(notify_get_state(heartbeatToken, &value) == NOTIFY_STATUS_OK)
            return value
        }
        let presence = AudioDevicePresence(notificationName: name, routing: noRoutes)
        precondition(heartbeat() == 0, "construction must not publish heartbeat")
        precondition(state() == 0, "construction must not activate a device")
        precondition(presence.start())
        precondition(state() == UInt64(getpid()), "start publishes actual PID")
        precondition(presence.start(), "idempotent start")
        let firstBeat = heartbeat()
        precondition(firstBeat > 0 && firstBeat <= mach_continuous_time(), "publish monotonic Mach ticks")
        Thread.sleep(forTimeInterval: 0.6)
        precondition(heartbeat() > firstBeat, "background heartbeat must advance without main runloop")
        presence.stop()
        precondition(heartbeat() == 0, "stop clears own heartbeat")
        Thread.sleep(forTimeInterval: 0.6)
        precondition(heartbeat() == 0, "cancelled timer must never republish after stop")
        precondition(state() == 0, "stop clears own publication")
        precondition(presence.start())
        precondition(notify_set_state(token, 42) == NOTIFY_STATUS_OK)
        presence.stop()
        precondition(state() == 42, "stop must preserve replacement host publication")
        var birthToken: Int32 = -1
        precondition(notify_register_check(name + ".start-time", &birthToken) == NOTIFY_STATUS_OK)
        defer { notify_cancel(birthToken) }
        precondition(presence.start())
        precondition(notify_set_state(birthToken, 123) == NOTIFY_STATUS_OK)
        precondition(notify_set_state(heartbeatToken, 987) == NOTIFY_STATUS_OK)
        Thread.sleep(forTimeInterval: 0.6)
        precondition(heartbeat() == 987, "timer must not renew replacement birth with same PID")
        presence.stop()
        precondition(state() == UInt64(getpid()) && heartbeat() == 987, "stop checks BOTH PID and birth")
        let group = DispatchGroup()
        for _ in 0..<8 {
            DispatchQueue.global().async(group: group) {
                for _ in 0..<100 { precondition(presence.start()); presence.stop() }
            }
        }
        group.wait()
        presence.stop()
        Thread.sleep(forTimeInterval: 0.6)
        precondition(state() == 0 && heartbeat() == 0, "concurrent start/stop must never resurrect cancelled generation")
        print("PASS heartbeat: advancing Mach ticks, stopped timer quiescence, PID+birth ownership, 800 concurrent start/stop cycles")
        // All route writes below are injected; no system device is changed.
        var current = "headphones"
        var available = ["speakers", "headphones"]
        var writes: [String] = []
        let routing = AudioPresenceRouting(
            defaultUID: { current }, availableUIDs: { available },
            builtInUID: { "speakers" }, setDefaultUID: { uid in current = uid; writes.append(uid); return true })
        let routed = AudioDevicePresence(notificationName: name, routing: routing)
        precondition(routed.start())
        current = "DualScreenAudio_UID"
        routed.stop()
        precondition(writes == ["headphones"], "restore prior headphones, not always speakers")
        writes = []
        precondition(routed.start())
        current = "speakers" // user changed route
        routed.stop()
        precondition(writes.isEmpty, "preserve user's non-tablet choice")
        current = "headphones"
        precondition(routed.start())
        available = ["speakers"] // old headphones unplugged
        current = "DualScreenAudio_UID"
        routed.stop()
        precondition(writes == ["speakers"], "choose available built-in only if prior device vanished")
        writes = []
        available = []
        precondition(routed.start())
        current = "DualScreenAudio_UID"
        routed.stop()
        precondition(writes.isEmpty, "no invalid/unknown-device writes; leave CoreAudio fallback")
        print("PASS safe routing: prior headphones restored, user choice preserved, unplugged fallback, no invalid writes")
        print("PASS host presence: inactive construction, PID publication, idempotent start/stop, replacement ownership")
    }
}
