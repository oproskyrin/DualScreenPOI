import Foundation

/// Pure tests for the clipboard sync decision core (docs/clipboard-sync.md).
/// No NSPasteboard — only ClipboardSyncCore, ClipboardHash and
/// ClipboardSyncFrame are exercised; the AppKit glue is verified live.
@main
struct ClipboardSyncTests {
    static var failures = 0

    static func check(_ condition: Bool, _ name: String) {
        if condition { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
    }

    static func main() {
        let cap = ClipboardSyncFrame.maxTextBytes

        // --- sha256 first-16-hex correctness (vectors from python hashlib) ---
        check(ClipboardHash.sixteenHex(of: "hello") == "2cf24dba5fb0a30e",
              "sha256-16hex known vector 'hello'")
        check(ClipboardHash.sixteenHex(of: "clipboard-sync") == "291e544243bbfa05",
              "sha256-16hex known vector 'clipboard-sync'")
        check(ClipboardHash.sixteenHex(of: "") == "e3b0c44298fc1c14",
              "sha256-16hex empty string")
        check(ClipboardHash.sixteenHex(of: "привет") == ClipboardHash.sixteenHex(of: String(decoding: "привет".utf8, as: UTF8.self)),
              "sha256-16hex is over utf-8 bytes")
        check(ClipboardHash.sixteenHex(of: "hello").count == 16, "hash is exactly 16 hex chars")

        // --- frame round-trip ---
        let roundTrip = ClipboardSyncFrame.decode(ClipboardSyncFrame.encode(text: "payload ✂️", hash: "0123456789abcdef")!)
        check(roundTrip?.text == "payload ✂️" && roundTrip?.hash == "0123456789abcdef",
              "0x06 frame round-trips text and hash")
        let bad = Data("{}".utf8)
        check(ClipboardSyncFrame.decode(bad) == nil, "frame decode rejects missing fields")

        // --- loop suppression: incoming apply, then echo of the same clip ---
        let tabletHash = ClipboardHash.sixteenHex(of: "from tablet")
        let core = ClipboardSyncCore()
        switch core.decideIncoming(text: "from tablet", hash: tabletHash) {
        case .apply(let text, let hash):
            check(text == "from tablet" && hash == tabletHash,
                  "new incoming clip is applied")
        default:
            check(false, "new incoming clip is applied")
        }
        if case .echoSkip = core.decideIncoming(text: "from tablet", hash: tabletHash) {
            check(true, "incoming echo of just-applied clip is skipped")
        } else {
            check(false, "incoming echo of just-applied clip is skipped")
        }

        // --- loop suppression: local detector sees the applied clip and stays silent ---
        if case .echoSkip = core.decideOutgoing(text: "from tablet") {
            check(true, "local change matching lastKnownHash is not sent")
        } else {
            check(false, "local change matching lastKnownHash is not sent")
        }

        // --- local change goes out and updates lastKnownHash ---
        let outgoingCore = ClipboardSyncCore()
        if case .send(let text, let hash) = outgoingCore.decideOutgoing(text: "local copy") {
            check(text == "local copy" && hash == ClipboardHash.sixteenHex(of: "local copy"),
                  "new local clip is sent with its hash")
        } else {
            check(false, "new local clip is sent with its hash")
        }
        if case .echoSkip = outgoingCore.decideIncoming(text: "local copy",
                                                        hash: ClipboardHash.sixteenHex(of: "local copy")) {
            check(true, "client echo of a local send is not re-applied")
        } else {
            check(false, "client echo of a local send is not re-applied")
        }

        // --- rate limit: 300 ms window, latest clip wins ---
        var fakeNow = DispatchTime(uptimeNanoseconds: 1_000_000_000)
        let rateCore = ClipboardSyncCore(now: { fakeNow })
        if case .send = rateCore.decideOutgoing(text: "first") {
            check(true, "rate limit: first send goes out")
        } else {
            check(false, "rate limit: first send goes out")
        }
        if case .rateLimited = rateCore.decideOutgoing(text: "second") {
            check(true, "rate limit: send inside 300 ms is deferred")
        } else {
            check(false, "rate limit: send inside 300 ms is deferred")
        }
        fakeNow = DispatchTime(uptimeNanoseconds: 1_000_000_000 + 400_000_000)
        if case .send(let text, _) = rateCore.decideOutgoing(text: "latest") {
            check(text == "latest", "rate limit: after the window the latest clip wins")
        } else {
            check(false, "rate limit: after the window the latest clip wins")
        }
        fakeNow = DispatchTime(uptimeNanoseconds: 1_000_000_000 + 500_000_000)
        if case .rateLimited = rateCore.decideOutgoing(text: "again") {
            check(true, "rate limit: window restarts after each send")
        } else {
            check(false, "rate limit: window restarts after each send")
        }

        // --- 1 MiB cap: outgoing oversized drop ---
        let bigOut = String(repeating: "x", count: cap + 1)
        if case .tooLarge(let bytes) = ClipboardSyncCore().decideOutgoing(text: bigOut) {
            check(bytes == cap + 1, "outgoing clip over 1 MiB is dropped with its size")
        } else {
            check(false, "outgoing clip over 1 MiB is dropped with its size")
        }
        let exactlyCap = String(repeating: "y", count: cap)
        if case .send = ClipboardSyncCore().decideOutgoing(text: exactlyCap) {
            check(true, "outgoing clip at exactly 1 MiB is allowed")
        } else {
            check(false, "outgoing clip at exactly 1 MiB is allowed")
        }

        // --- 1 MiB cap: incoming oversized drop ---
        let inCore = ClipboardSyncCore()
        if case .tooLarge(let bytes) = inCore.decideIncoming(text: bigOut, hash: "bbbbbbbbbbbbbbbb") {
            check(bytes == cap + 1, "incoming clip over 1 MiB is dropped with its size")
        } else {
            check(false, "incoming clip over 1 MiB is dropped with its size")
        }
        // Dropped incoming clip must not set lastKnownHash (size-only log, no state).
        if case .apply(let text, _) = inCore.decideIncoming(text: "after drop", hash: "cccccccccccccccc"),
           text == "after drop" {
            check(true, "oversized drop leaves loop suppression state intact")
        } else {
            check(false, "oversized drop leaves loop suppression state intact")
        }
        if case .echoSkip = inCore.decideIncoming(text: "after drop", hash: "cccccccccccccccc") {
            check(true, "applied incoming clip sets lastKnownHash")
        } else {
            check(false, "applied incoming clip sets lastKnownHash")
        }

        if failures > 0 { print("\(failures) failure(s)"); exit(1) }
        print("all clipboard sync tests passed")
    }
}
