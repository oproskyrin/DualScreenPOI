import Foundation

@main
struct BitratePolicyTests {
    static var failures = 0

    static func check(_ condition: Bool, _ name: String) {
        if condition { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
    }

    static func main() {
        // End-to-end latency wins over decoder latency: a congested pipe must
        // cut, even when the decoder itself looks fast.
        let congested = BitratePolicy.next(currentBps: 60_000_000, maxBps: 60_000_000,
                                           latencyMs: 300, decoderMs: 6, goodWindows: 2)
        check(congested.bitrateBps == 45_000_000, "congested end-to-end latency cuts 25%")
        check(congested.goodWindows == 0, "congestion resets the good-window counter")

        // Decoder-only complaint must not move the bitrate when end-to-end is healthy.
        let decoderOnly = BitratePolicy.next(currentBps: 60_000_000, maxBps: 60_000_000,
                                             latencyMs: 28, decoderMs: 300, goodWindows: 0)
        check(decoderOnly.bitrateBps == 60_000_000, "healthy end-to-end latency ignores decoder spikes")

        // Without end-to-end telemetry fall back to the decoder metric.
        let fallback = BitratePolicy.next(currentBps: 60_000_000, maxBps: 60_000_000,
                                          latencyMs: nil, decoderMs: 300, goodWindows: 0)
        check(fallback.bitrateBps == 45_000_000, "decoder latency is the fallback signal")

        // No signal at all: hold, never invent a change.
        let silent = BitratePolicy.next(currentBps: 40_000_000, maxBps: 40_000_000,
                                        latencyMs: nil, decoderMs: nil, goodWindows: 0)
        check(!silent.changed, "no telemetry holds the bitrate")

        // Growth needs two consecutive healthy windows.
        let firstGood = BitratePolicy.next(currentBps: 60_000_000, maxBps: 78_000_000, latencyMs: 25,
                                           decoderMs: 6, goodWindows: 0)
        check(firstGood.bitrateBps == 60_000_000 && firstGood.goodWindows == 1,
              "first healthy window only arms the counter")
        let secondGood = BitratePolicy.next(currentBps: 60_000_000, maxBps: 78_000_000, latencyMs: 25,
                                            decoderMs: 6, goodWindows: 1)
        check(secondGood.bitrateBps == 72_000_000, "second healthy window grows 20%")

        // The floor and ceiling both bind.
        let floor = BitratePolicy.next(currentBps: 8_500_000, maxBps: 60_000_000,
                                       latencyMs: 900, decoderMs: 6, goodWindows: 0)
        check(floor.bitrateBps == 30_000_000, "bitrate never drops below half the target")
        let ceiling = BitratePolicy.next(currentBps: 60_000_000, maxBps: 60_000_000,
                                         latencyMs: 20, decoderMs: 6, goodWindows: 2)
        check(ceiling.bitrateBps == 60_000_000, "bitrate never exceeds the ceiling")

        // Elevation band backs off gently instead of slamming the pipe.
        let elevated = BitratePolicy.next(currentBps: 60_000_000, maxBps: 60_000_000,
                                          latencyMs: 120, decoderMs: 6, goodWindows: 1)
        check(elevated.bitrateBps == 54_000_000, "elevated latency cuts 10%")

        // Mid-band (between healthy and elevated) neither grows nor cuts.
        let mid = BitratePolicy.next(currentBps: 60_000_000, maxBps: 60_000_000,
                                     latencyMs: 80, decoderMs: 6, goodWindows: 2)
        check(mid.bitrateBps == 60_000_000 && mid.goodWindows == 0, "mid band holds and resets windows")

        if failures > 0 { print("\(failures) failure(s)"); exit(1) }
        print("all bitrate policy tests passed")
    }
}
