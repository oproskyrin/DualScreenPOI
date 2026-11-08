import Foundation
import AppKit
import CryptoKit

/// DSXP frame 0x06 clipboard sync (see docs/clipboard-sync.md).
///
/// Layout mirrors BitratePolicy: a pure, injectable decision core
/// (`ClipboardSyncCore` + `ClipboardSyncFrame`) with a thin NSPasteboard
/// glue class on top. Only the glue touches AppKit; every rule below is
/// unit-tested without a pasteboard.
///
/// Privacy: clipboard text is never logged — sizes and hashes only.

// MARK: - Hash

/// First 16 hex chars of sha256(text utf-8). Loop suppression only,
/// never security.
enum ClipboardHash {
    static func sixteenHex(of text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Frame codec

enum ClipboardSyncFrame {
    static let version = 1
    /// Text cap in UTF-8 bytes (1 MiB). Oversized clips are dropped by the
    /// receiver with a size-only log line.
    static let maxTextBytes = 1 << 20

    /// {"v":1,"text":...,"hash":"16 hex of sha256(text)"}
    static func encode(text: String, hash: String) -> Data? {
        let json: [String: Any] = ["v": version, "text": text, "hash": hash]
        return try? JSONSerialization.data(withJSONObject: json)
    }

    static func decode(_ payload: Data) -> (text: String, hash: String)? {
        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              (json["v"] as? Int) == version,
              let text = json["text"] as? String,
              let hash = json["hash"] as? String
        else { return nil }
        return (text, hash)
    }
}

// MARK: - Pure decision core

/// Loop suppression + rate limit + size cap, per docs/clipboard-sync.md.
/// One `lastKnownHash` covers both directions: a programmatic set updates our
/// own clipboard, the detector sees the matching hash and stays silent.
final class ClipboardSyncCore {
    /// At most one outgoing frame per 300 ms; latest clip wins.
    static let minSendInterval: TimeInterval = 0.3

    enum Outgoing: Equatable {
        case send(text: String, hash: String)
        /// Same hash as the clip we just applied — it is our own echo.
        case echoSkip
        /// Exceeds the 1 MiB cap; caller logs the size only.
        case tooLarge(bytes: Int)
        /// Inside the 300 ms window; caller retries with the latest text.
        case rateLimited
    }

    enum Incoming: Equatable {
        case apply(text: String, hash: String)
        case echoSkip
        case tooLarge(bytes: Int)
    }

    private(set) var lastKnownHash: String?
    private var lastSend: DispatchTime?
    private let now: () -> DispatchTime

    init(now: @escaping () -> DispatchTime = DispatchTime.now) {
        self.now = now
    }

    /// A local pasteboard change was detected with this text.
    func decideOutgoing(text: String) -> Outgoing {
        let hash = ClipboardHash.sixteenHex(of: text)
        if hash == lastKnownHash { return .echoSkip }
        let bytes = text.utf8.count
        guard bytes <= ClipboardSyncFrame.maxTextBytes else { return .tooLarge(bytes: bytes) }
        if let last = lastSend,
           now().uptimeNanoseconds - last.uptimeNanoseconds < UInt64(ClipboardSyncCore.minSendInterval * 1_000_000_000) {
            return .rateLimited
        }
        lastSend = now()
        lastKnownHash = hash
        return .send(text: text, hash: hash)
    }

    /// A 0x06 frame arrived with this text/hash.
    func decideIncoming(text: String, hash: String) -> Incoming {
        let bytes = text.utf8.count
        guard bytes <= ClipboardSyncFrame.maxTextBytes else { return .tooLarge(bytes: bytes) }
        if hash == lastKnownHash { return .echoSkip }
        lastKnownHash = hash
        return .apply(text: text, hash: hash)
    }
}

// MARK: - Pasteboard glue

/// Polls `NSPasteboard.general.changeCount` every 700 ms on a utility queue
/// while a clipboard-capable client is connected, and applies incoming 0x06
/// text to the general pasteboard. One instance per client session; created
/// by FrameServer when the hello advertises "clipboard": true.
final class ClipboardSync {
    /// 700 ms poll cadence from docs/clipboard-sync.md.
    static let pollInterval: TimeInterval = 0.7

    private let core = ClipboardSyncCore()
    private let log: HostLog
    private let sendFrame: (Data) -> Void
    private let pollQueue = DispatchQueue(label: "ds.clipboard", qos: .utility)
    private var pollTimer: DispatchSourceTimer?
    private var lastChangeCount = 0
    /// Clip observed but not yet sent (rate-limited); replaced by newer text,
    /// flushed on the next tick — latest clip wins.
    private var pending: (text: String, hash: String)?

    init(log: HostLog, sendFrame: @escaping (Data) -> Void) {
        self.log = log
        self.sendFrame = sendFrame
    }

    func start() {
        pollQueue.sync {
            guard pollTimer == nil else { return }
            lastChangeCount = NSPasteboard.general.changeCount
            let timer = DispatchSource.makeTimerSource(queue: pollQueue)
            timer.schedule(deadline: .now() + ClipboardSync.pollInterval,
                           repeating: ClipboardSync.pollInterval)
            timer.setEventHandler { [weak self] in self?.pollOnce() }
            timer.resume()
            pollTimer = timer
        }
        log.write("clipboard sync started")
    }

    func stop() {
        pollQueue.sync {
            pollTimer?.cancel()
            pollTimer = nil
            pending = nil
        }
        log.write("clipboard sync stopped")
    }

    /// Incoming 0x06 payload from FrameServer.
    func handleIncoming(payload: Data) {
        guard let frame = ClipboardSyncFrame.decode(payload) else {
            log.write("clipboard incoming dropped malformedFrame bytes=\(payload.count)")
            return
        }
        switch core.decideIncoming(text: frame.text, hash: frame.hash) {
        case .apply(let text, _):
            applyIncoming(text: text)
        case .echoSkip:
            break
        case .tooLarge(let bytes):
            log.write("clipboard incoming dropped bytes=\(bytes) exceedsCap")
        }
    }

    /// Writes the received text to the general pasteboard.
    func applyIncoming(text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([text as NSString])
            // The detector must ignore the change we just caused.
            self.pollQueue.sync { self.lastChangeCount = pb.changeCount }
        }
    }

    /// One poll tick: detect local changes, flush a rate-limited pending clip.
    private func pollOnce() {
        let pb = NSPasteboard.general
        let count = pb.changeCount
        if count != lastChangeCount {
            lastChangeCount = count
            if let text = pb.string(forType: .string), !text.isEmpty {
                pending = (text, ClipboardHash.sixteenHex(of: text))
            }
            // Read failure (nil/empty): nothing to send this tick; the next
            // user copy bumps changeCount again. Sizes only, never content.
        }
        guard let clip = pending else { return }
        switch core.decideOutgoing(text: clip.text) {
        case .send(let text, let hash):
            pending = nil
            if let data = ClipboardSyncFrame.encode(text: text, hash: hash) {
                sendFrame(data)
            }
        case .echoSkip:
            pending = nil
        case .tooLarge(let bytes):
            pending = nil
            log.write("clipboard outgoing dropped bytes=\(bytes) exceedsCap")
        case .rateLimited:
            break // keep pending; latest clip wins, retry next tick
        }
    }
}
