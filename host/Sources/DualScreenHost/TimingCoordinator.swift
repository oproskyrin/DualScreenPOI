import Foundation

// Host-side latency measurement support (pure Foundation, no AppKit —
// unit-testable standalone via scripts/test-host-timing.sh).
//
// Wire protocol additions (DSXP):
//   type 0x05 = video timing JSON, sent immediately BEFORE each 0x01 frame:
//     {"seq":Int, "cap":Double, "enc":Double}   (all host uptime nanoseconds
//     except seq, which is monotonic per connection)
//   host 0x03 stats gain: "hostNow":Double (host uptime ns),
//     "sync":{"t1","t2","t3"} (NTP-lite echo of the client's last t1) and
//     "inProbe":{"ts","arr"} (raw echo of the last input ts + host arrival).
//
// The host does NO offset math for input transit — the client computes the
// clock offset itself from t1..t4 and applies it to the raw ts/arr pair.

/// Pairs captured frame times with encoded packets for the 0x05 timing
/// sidecar. One cap time is pushed right before every `encoder.encode` call
/// and popped when the encoded packet is emitted. If the encoder drops a
/// submitted frame the FIFO desyncs; a failed pop still consumes a sequence
/// number so the client can detect the gap by seq, and the monotonic `cap`
/// plus "hostNow" in stats let the client sanity-check pairing.
final class TimingFIFO {
    struct Timing {
        let seq: Int
        let cap: Double
        let enc: Double
    }

    private let lock = NSLock()
    private var caps: [Double] = []
    private var seq = 0

    /// Record the capture time (host uptime ns) of a frame submitted to the encoder.
    func push(capNs: Double) {
        lock.lock(); defer { lock.unlock() }
        caps.append(capNs)
    }

    /// Pair the oldest pending cap time with `encNs` (host uptime ns when the
    /// encoded packet was emitted). Returns nil when no cap is pending
    /// (encoder dropped a frame); the seq counter still advances so sent
    /// sidecars carry gaps the client tolerates by seq.
    func pop(encNs: Double) -> Timing? {
        lock.lock(); defer { lock.unlock() }
        let current = seq
        seq += 1
        guard !caps.isEmpty else { return nil }
        return Timing(seq: current, cap: caps.removeFirst(), enc: encNs)
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return caps.count
    }

    /// Drain pending caps and restart seq at 0 — call on client (re)connect
    /// ("seq" is per connection) and on pipeline reset (stale caps must not
    /// pair with packets of a new configuration).
    func reset() {
        lock.lock(); defer { lock.unlock() }
        caps.removeAll(keepingCapacity: true)
        seq = 0
    }
}

/// NTP-lite clock sync echo. The client's 0x03 stats carry "t1" (its uptime
/// ns when it sent them); the host must echo that t1 in its NEXT 0x03 send
/// together with t2 (host uptime ns when the client stats arrived) and t3
/// (host uptime ns when the reply is sent). Only the last t1/t2 pair is kept.
final class ClockSyncEcho {
    private let lock = NSLock()
    private var t1: Double?
    private var t2: Double?

    /// Record the arrival of a client stats frame. Stats without "t1" are
    /// ignored (older clients, no echo requested) and never clobber a pair
    /// still waiting to be echoed.
    func noteArrival(t1: Double?, hostArrivalNs: Double) {
        guard let t1 else { return }
        lock.lock(); defer { lock.unlock() }
        self.t1 = t1
        self.t2 = hostArrivalNs
    }

    /// The "sync" object for the next host stats send, or nil when nothing is
    /// pending. Consumes the pair: the echo appears in exactly one stats send.
    func takePayload(nowNs: Double) -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        guard let t1, let t2 else { return nil }
        self.t1 = nil
        self.t2 = nil
        return ["t1": t1, "t2": t2, "t3": nowNs]
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        t1 = nil
        t2 = nil
    }
}

/// Raw echo of the last input event carrying a "ts" field (client uptime ns):
/// reports {"ts": ts, "arr": host uptime ns of its arrival} inside host stats.
/// The host performs no offset or transit computation — the client, which
/// alone sees t1..t4, derives the clock offset and computes transit itself.
final class InputProbeEcho {
    private let lock = NSLock()
    private var pending: (ts: Double, arr: Double)?

    /// Record the arrival of an input event. Events without "ts" are ignored
    /// and never clobber a probe still waiting to be echoed.
    func note(ts: Double?, arrivalNs: Double) {
        guard let ts else { return }
        lock.lock(); defer { lock.unlock() }
        pending = (ts, arrivalNs)
    }

    /// The "inProbe" object for the next host stats send, or nil. Consumed by
    /// one stats send so stale probes are never re-echoed.
    func takePayload() -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        guard let pending else { return nil }
        self.pending = nil
        return ["ts": pending.ts, "arr": pending.arr]
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        pending = nil
    }
}
