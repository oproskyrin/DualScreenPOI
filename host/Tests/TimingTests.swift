import Foundation

// Pure-logic regression tests for host-side latency measurement:
//   - TimingFIFO: 0x05 video timing sidecar pairing (push/pop/skip/reset)
//   - ClockSyncEcho: NTP-lite t1/t2 bookkeeping, one-shot echo in next stats
//   - InputProbeEcho: raw ts/arr passthrough, no offset math on the host
// Compiled standalone with swiftc (see scripts/test-host-timing.sh).

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { print("FAIL: \(message)"); exit(1) }
}

@main struct TimingTests {
    static func main() {
        timingFIFO()
        clockSyncEcho()
        inputProbeEcho()
        jsonFieldNames()
        print("PASS: all timing tests")
    }

    // MARK: TimingFIFO

    static func timingFIFO() {
        let fifo = TimingFIFO()

        // Empty pop fails (encoder emitted a packet with no pending cap) and
        // consumes a sequence number so the client sees a gap by seq.
        check(fifo.pop(encNs: 50) == nil, "pop on empty FIFO must fail")
        check(fifo.count == 0, "failed pop must not queue anything")

        // Push/pop pairing preserves arrival order; seq is monotonic.
        fifo.push(capNs: 100)
        fifo.push(capNs: 200)
        fifo.push(capNs: 300)
        check(fifo.count == 3, "three caps pending")
        let first = fifo.pop(encNs: 150)
        check(first?.seq == 1, "first paired pop skips the failed seq (gap tolerated by client), got \(String(describing: first?.seq))")
        check(first?.cap == 100, "oldest cap popped first, got \(String(describing: first?.cap))")
        check(first?.enc == 150, "enc time passes through, got \(String(describing: first?.enc))")
        let second = fifo.pop(encNs: 250)
        check(second?.seq == 2 && second?.cap == 200, "second pair in order")
        let third = fifo.pop(encNs: 350)
        check(third?.seq == 3 && third?.cap == 300, "third pair in order")
        check(fifo.pop(encNs: 400) == nil, "drained FIFO pops nil")
        print("PASS: timing FIFO push/pop order and seq gaps")

        // reset(): clears pending caps AND the per-connection seq (new client).
        let fresh = TimingFIFO()
        fresh.push(capNs: 10)
        _ = fresh.pop(encNs: 20)
        fresh.push(capNs: 30)
        fresh.reset()
        check(fresh.count == 0, "reset drains pending caps")
        check(fresh.pop(encNs: 40) == nil, "reset leaves no stale caps to pop")
        fresh.reset() // reconnect: seq restarts after the gap check above
        fresh.push(capNs: 1000)
        let afterReset = fresh.pop(encNs: 1100)
        check(afterReset?.seq == 0 && afterReset?.cap == 1000,
              "reset restarts seq at 0 for the new connection, got \(String(describing: afterReset?.seq))")
        print("PASS: timing FIFO reset restarts per-connection seq")

        // Concurrency smoke: parallel pushes and pops never crash or corrupt.
        let shared = TimingFIFO()
        let group = DispatchGroup()
        let pushers = 4, perThread = 5_000
        for t in 0..<pushers {
            group.enter()
            DispatchQueue.global().async {
                for i in 0..<perThread { shared.push(capNs: Double(t * perThread + i)) }
                group.leave()
            }
        }
        var popped = 0
        let popLock = NSLock()
        for _ in 0..<pushers {
            group.enter()
            DispatchQueue.global().async {
                var local = 0
                for _ in 0..<perThread { if shared.pop(encNs: 0) != nil { local += 1 } }
                popLock.lock(); popped += local; popLock.unlock()
                group.leave()
            }
        }
        check(group.wait(timeout: .now() + 30) == .success, "concurrent FIFO work finishes")
        check(popped <= pushers * perThread, "pops never exceed pushes")
        check(shared.count == pushers * perThread - popped, "FIFO accounting exact under contention")
        print("PASS: timing FIFO is thread-safe")
    }

    // MARK: ClockSyncEcho

    static func clockSyncEcho() {
        let sync = ClockSyncEcho()

        // No client stats yet -> nothing to echo, no crash.
        check(sync.takePayload(nowNs: 1) == nil, "no payload before any client t1")

        // Stats without t1 must not crash and must not produce an echo.
        sync.noteArrival(t1: nil, hostArrivalNs: 2)
        check(sync.takePayload(nowNs: 3) == nil, "missing t1 produces no echo")

        // The echo is exactly the recorded pair plus the reply timestamp.
        sync.noteArrival(t1: 111, hostArrivalNs: 222)
        let payload = sync.takePayload(nowNs: 333)
        check(payload?["t1"] as? Double == 111, "sync.t1 echoes client t1")
        check(payload?["t2"] as? Double == 222, "sync.t2 is host arrival of that client stats")
        check(payload?["t3"] as? Double == 333, "sync.t3 is reply send time")
        check(payload?.count == 3, "sync payload carries only t1/t2/t3")

        // Echo is one-shot: the NEXT stats send consumed it.
        check(sync.takePayload(nowNs: 444) == nil, "sync echo consumed by the next stats send")

        // Only the LAST t1/t2 pair is kept when several arrive before a send.
        sync.noteArrival(t1: 1000, hostArrivalNs: 2000)
        sync.noteArrival(t1: 3000, hostArrivalNs: 4000)
        let last = sync.takePayload(nowNs: 5000)
        check(last?["t1"] as? Double == 3000 && last?["t2"] as? Double == 4000,
              "sync keeps only the last t1/t2 pair")
        check(sync.takePayload(nowNs: 6000) == nil, "consumed again")

        // reset drops any pending pair.
        sync.noteArrival(t1: 7, hostArrivalNs: 8)
        sync.reset()
        check(sync.takePayload(nowNs: 9) == nil, "reset clears pending sync pair")
        print("PASS: clock sync echo bookkeeping")
    }

    // MARK: InputProbeEcho

    static func inputProbeEcho() {
        let probe = InputProbeEcho()

        check(probe.takePayload() == nil, "no probe before any input ts")

        // Input without ts (older client): no crash, no payload, no clobber.
        probe.note(ts: 100, arrivalNs: 200)
        let pending = probe.takePayload()
        check(pending?["ts"] as? Double == 100 && pending?["arr"] as? Double == 200,
              "probe echoes raw ts/arr pair")
        probe.note(ts: nil, arrivalNs: 300)
        check(probe.takePayload() == nil, "missing ts produces no probe echo")

        // Only the last pair is echoed, once per arrival.
        probe.note(ts: 1000, arrivalNs: 2000)
        probe.note(ts: 3000, arrivalNs: 4000)
        let last = probe.takePayload()
        check(last?["ts"] as? Double == 3000 && last?["arr"] as? Double == 4000,
              "probe keeps only the last ts/arr pair")
        check(last?.count == 2, "probe payload carries only ts/arr")
        check(probe.takePayload() == nil, "probe echo consumed by one stats send")

        // reset clears a pending probe.
        probe.note(ts: 5, arrivalNs: 6)
        probe.reset()
        check(probe.takePayload() == nil, "reset clears pending probe")
        print("PASS: input probe echo passthrough")
    }

    // MARK: wire format

    static func jsonFieldNames() {
        // The exact bytes the tablet will parse: field names and JSON types.
        let fifo = TimingFIFO()
        fifo.push(capNs: 123.5)
        guard let timing = fifo.pop(encNs: 456.5) else {
            print("FAIL: pop for wire-format check"); exit(1)
        }
        let wire: [String: Any] = ["seq": timing.seq, "cap": timing.cap, "enc": timing.enc]
        let data = try! JSONSerialization.data(withJSONObject: wire)
        let round = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        check(round["seq"] as? Int == timing.seq, "0x05 \"seq\" survives JSON as Int")
        check(round["cap"] as? Double == 123.5, "0x05 \"cap\" survives JSON as Double")
        check(round["enc"] as? Double == 456.5, "0x05 \"enc\" survives JSON as Double")

        let sync = ClockSyncEcho()
        sync.noteArrival(t1: 1.5, hostArrivalNs: 2.5)
        let syncWire: [String: Any] = ["sync": sync.takePayload(nowNs: 3.5)!, "hostNow": 3.5]
        let syncData = try! JSONSerialization.data(withJSONObject: syncWire)
        let syncRound = try! JSONSerialization.jsonObject(with: syncData) as! [String: Any]
        let syncObj = syncRound["sync"] as? [String: Any]
        check(syncObj?["t1"] as? Double == 1.5, "stats \"sync\".\"t1\" wire name")
        check(syncObj?["t2"] as? Double == 2.5, "stats \"sync\".\"t2\" wire name")
        check(syncObj?["t3"] as? Double == 3.5, "stats \"sync\".\"t3\" wire name")
        check(syncRound["hostNow"] as? Double == 3.5, "stats \"hostNow\" wire name")

        let probe = InputProbeEcho()
        probe.note(ts: 9.5, arrivalNs: 10.5)
        let probeWire: [String: Any] = ["inProbe": probe.takePayload()!]
        let probeRound = try! JSONSerialization.jsonObject(with: try! JSONSerialization.data(withJSONObject: probeWire)) as! [String: Any]
        let probeObj = probeRound["inProbe"] as? [String: Any]
        check(probeObj?["ts"] as? Double == 9.5, "stats \"inProbe\".\"ts\" wire name")
        check(probeObj?["arr"] as? Double == 10.5, "stats \"inProbe\".\"arr\" wire name")
        print("PASS: wire field names and JSON types")
    }
}
