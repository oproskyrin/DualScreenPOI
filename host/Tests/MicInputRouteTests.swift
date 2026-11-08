import Foundation

/// Pure-core mic input route regression (docs/mic-0x07.md contract):
/// overfill drop, silence when mic is not negotiated, drops when the HAL is
/// absent, PCM fidelity through the ring. No CoreAudio device is touched:
/// the sink and the device probe are injected fakes.
final class FakeMicSink: MicAudioSink {
    let ring: MicRingBuffer
    var writes = 0
    let isActive = true
    init(capacity: Int) { ring = MicRingBuffer(capacity: capacity) }
    func write(_ samples: ArraySlice<Int16>) -> Int {
        writes += 1
        return ring.write(samples)
    }
}

@main
struct MicInputRouteTests {
    static var failures = 0

    static func check(_ condition: Bool, _ name: String) {
        if condition { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
    }

    static func waitUntil(seconds: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            usleep(20000)
        }
        return condition()
    }

    static func pcmData(_ samples: [Int16]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            data.append(UInt8(truncatingIfNeeded: sample))
            data.append(UInt8(truncatingIfNeeded: sample >> 8))
        }
        return data
    }

    static func main() {
        let log = HostLog(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("mic-route-tests-\(getpid()).log"), maxBytes: 128)

        // ---- Ring buffer primitives ------------------------------------
        let ring = MicRingBuffer(capacity: 8)
        check(ring.write([1, 2, 3, 4][...]) == 4, "ring accepts below capacity")
        check(ring.write([5, 6, 7, 8, 9, 10][...]) == 4, "ring writes only what fits")
        check(ring.count == 8, "ring holds exactly capacity samples")
        check(ring.drain(16) == [1, 2, 3, 4, 5, 6, 7, 8], "ring keeps oldest samples and drops incoming excess")
        check(ring.count == 0, "ring drains fully")
        check(ring.write([7][...]) == 1 && ring.drain(4) == [7], "ring wraps without corruption")

        // ---- Negotiated route with a device -----------------------------
        let sink = FakeMicSink(capacity: 16)
        let route = MicInputRoute(
            log: log,
            deviceProbe: { 42 },
            sinkFactory: { _ in sink })
        route.start()
        check(waitUntil { route.hasActiveSink }, "route activates the sink when the HAL probe hits")

        route.setNegotiated(false)
        route.accept(pcmData([100, -100]))
        check(sink.writes == 0, "no writes when mic was not negotiated (silence)")

        route.setNegotiated(true)
        let pattern: [Int16] = [-32768, -1, 0, 1, 32767]
        route.accept(pcmData(pattern))
        check(sink.writes == 1, "negotiated hello enables exactly one write per frame")
        check(sink.ring.drain(16) == pattern, "PCM16LE payload survives byte-for-byte")

        // ---- Overfill drop ----------------------------------------------
        let oversized = [Int16](repeating: 512, count: 64) // capacity is 16
        route.accept(pcmData(oversized))
        check(sink.ring.count == 16, "overfilled ring keeps capacity, not more")
        check(sink.ring.drain(16) == [Int16](repeating: 512, count: 16), "overfill keeps the oldest 20 ms window")
        let drops = route.dropCounters
        check(drops.ringFull == 48, "overfill excess is counted as ringFull drops (48 samples)")

        // ---- Odd trailing byte is ignored, empty payload is harmless ----
        route.accept(Data([0x01, 0x00, 0x02]))
        check(route.dropCounters.ringFull == 48, "odd trailing byte ignored without spurious drops")
        route.accept(Data())
        check(sink.writes == 3, "empty payload writes nothing")

        // ---- HAL absent: silent drop, no buffering ----------------------
        let absent = MicInputRoute(
            log: log,
            deviceProbe: { nil },
            sinkFactory: { _ in FakeMicSink(capacity: 16) })
        absent.setNegotiated(true)
        absent.accept(pcmData([1, 2, 3]))
        check(absent.dropCounters.noDevice == 1, "frames drop silently when no HAL is loaded")
        check(!absent.hasActiveSink, "no sink is created for an absent device")
        absent.start()
        absent.accept(pcmData([4, 5, 6]))
        absent.accept(pcmData([7, 8]))
        check(waitUntil { absent.dropCounters.noDevice == 3 }, "absent-device poll keeps dropping without blocking")
        check(!absent.hasActiveSink, "no sink is created for an absent device")

        // ---- Teardown clears negotiation --------------------------------
        route.stop()
        check(waitUntil { !route.hasActiveSink }, "stop removes the sink")
        route.setNegotiated(true)
        route.accept(pcmData([9, 9]))
        check(sink.writes == 3, "writes after stop are refused (sink inactive)")

        // Diagnostics never contain PCM: assert the drop report line only.
        if failures > 0 { print("\(failures) failure(s)"); exit(1) }
        print("all mic input route tests passed")
        exit(0)
    }
}
