import Foundation

/// AIMD policy for the live bitrate, kept pure so it is testable without a host.
///
/// The client reports both decoder latency and end-to-end capture->render
/// latency. Only the latter reflects queueing on the wire and in the encoder
/// backlog, so it is preferred: reacting to decoder latency alone cut the
/// bitrate while the real bottleneck (SCK backlog) stayed untouched.
enum BitratePolicy {
    static let floorBps = 8_000_000
    // Bands are deliberately wide: capture->render jitters by 10-20 ms at
    // 2944x1840, and a policy that treats 45 ms as congestion never climbs
    // back off the 8 Mbit/s floor. Only a real backlog (well past 100 ms)
    // counts as congestion.
    /// Latency above this means queues are filling: back off hard.
    static let congestedMs = 120.0
    /// Latency in this band is borderline: back off gently.
    static let elevatedMs = 85.0
    /// Below this the pipe is healthy: allow a step up.
    static let healthyMs = 60.0

    struct Decision {
        let bitrateBps: Int
        let goodWindows: Int
        let changed: Bool
    }

    /// - Parameters:
    ///   - latencyMs: preferred end-to-end client latency; nil when unavailable.
    ///   - decoderMs: fallback signal when the client has no synced clock yet.
    static func next(currentBps: Int, maxBps: Int, latencyMs: Double?,
                     decoderMs: Double?, goodWindows: Int) -> Decision {
        guard let latency = latencyMs ?? decoderMs, latency.isFinite else {
            return Decision(bitrateBps: currentBps, goodWindows: 0, changed: false)
        }
        var next = currentBps
        var windows = goodWindows
        if latency > congestedMs {
            next = Int(Double(currentBps) * 0.75)
            windows = 0
        } else if latency > elevatedMs {
            next = Int(Double(currentBps) * 0.9)
            windows = 0
        } else if latency < healthyMs {
            windows += 1
            // Two healthy windows in a row (>= 6 s) are enough to climb back
            // quickly after a transient stall; +20% per step still ramps gently.
            if windows >= 2 {
                next = min(Int(Double(currentBps) * 1.2), maxBps)
                windows = 0
            }
        } else {
            windows = 0
        }
        next = max(next, floorBps)
        next = min(next, max(maxBps, floorBps))
        return Decision(bitrateBps: next, goodWindows: windows, changed: next != currentBps)
    }
}
