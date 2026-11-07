import Foundation
import Network

/// TCP server speaking DSXP (DualScreen eXtension Protocol), v1.
///
/// Framing: [u8 type][u32 BE length][payload]
///   type 0x00 = control (JSON)
///   type 0x01 = video (Annex-B HEVC access unit)
///   type 0x02 = input event (JSON, tablet -> mac)
///   type 0x03 = stats (JSON, both ways)
///
/// Handshake: the client connects and sends type 0x00
/// {"magic":"DSXP","version":1,"width":W,"height":H,"maxRefresh":R}.
/// The server replies type 0x00 with the negotiated session config and then
/// starts streaming video.
final class FrameServer {
    enum ServerError: Error {
        case listenerFailed(Error)
    }

    static let defaultPort: UInt16 = 7381

    private let queue = DispatchQueue(label: "ds.server")
    private var listener: NWListener?
    private(set) var connection: NWConnection?
    private var clientHello: [String: Any]?
    private let log: HostLog
    private var sessionNumber = 0
    private var sessionStarted = DispatchTime.now()
    private var receivedBytes = 0
    private var processedBytes = 0

    init(log: HostLog = .shared) {
        self.log = log
    }

    /// JSON control messages from the tablet (the hello first).
    var onControl: (([String: Any]) -> Void)?
    /// JSON input events from the tablet.
    var onInput: (([String: Any]) -> Void)?
    /// Periodic stats from the tablet (latency, decode fps).
    var onClientStats: (([String: Any]) -> Void)?
    var onClientConnected: (() -> Void)?
    var onClientDisconnected: (() -> Void)?

    private var rxBuffer = Data()

    func start(port: UInt16 = FrameServer.defaultPort) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        let startup = ListenerStartup()
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                startup.resolve(nil)
            case .failed(let error), .waiting(let error):
                self?.log.write("server listener failed: \(error)")
                startup.resolve(error)
            default: break
            }
        }
        // Announce the host on the local network: Android client discovers
        // "_dualscreen._tcp" and connects without typing the Mac's IP.
        listener.service = NWListener.Service(name: "DualScreen", type: "_dualscreen._tcp")
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            self.queue.async {
                // single-client for now: drop previous connection
                if let old = self.connection {
                    self.teardown(old, reason: "replaced by a new client")
                }
                self.accept(conn)
            }
        }
        self.listener = listener
        listener.start(queue: queue)
        log.write("server listener starting port=\(port)")
        guard startup.semaphore.wait(timeout: .now() + 5) == .success else {
            stop()
            throw ServerError.listenerFailed(NWError.posix(.ETIMEDOUT))
        }
        if let error = queue.sync(execute: { startup.error }) {
            stop()
            throw ServerError.listenerFailed(error)
        }
    }

    /// Main-thread caller. Drain queued sends and close the old listener before
    /// Sparkle terminates/relaunches the process; safe after partial startup.
    func stop() {
        queue.sync {
            listener?.newConnectionHandler = nil
            listener?.stateUpdateHandler = nil
            listener?.cancel()
            listener = nil
            if let connection { teardown(connection, reason: "host stopping") }
        }
    }

    private final class ListenerStartup {
        let semaphore = DispatchSemaphore(value: 0)
        var error: Error?
        private var resolved = false
        func resolve(_ error: Error?) {
            guard !resolved else { return }
            resolved = true
            self.error = error
            semaphore.signal()
        }
    }

    private func accept(_ conn: NWConnection) {
        connection = conn
        clientHello = nil
        rxBuffer.removeAll(keepingCapacity: true)
        sessionNumber += 1
        sessionStarted = .now()
        receivedBytes = 0
        processedBytes = 0
        log.write("session=\(sessionNumber) accepted peer=\(conn.endpoint)")
        conn.stateUpdateHandler = { [weak self] state in
            guard let self, self.connection === conn else { return }
            switch state {
            case .ready:
                self.log.write("session=\(self.sessionNumber) connected peer=\(conn.endpoint)")
                self.onClientConnected?()
                self.receiveLoop(conn)
            case .failed(let e):
                self.teardown(conn, reason: "connection failed: \(e)")
            case .cancelled:
                self.teardown(conn, reason: "connection cancelled")
            case .waiting(let error):
                self.log.write("session=\(self.sessionNumber) waiting: \(error)")
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func teardown(_ conn: NWConnection, reason: String) {
        guard connection === conn else { return }
        connection = nil
        clientHello = nil
        rxBuffer.removeAll(keepingCapacity: true)
        conn.stateUpdateHandler = nil
        conn.cancel()
        let elapsedMs = (DispatchTime.now().uptimeNanoseconds - sessionStarted.uptimeNanoseconds) / 1_000_000
        log.write("session=\(sessionNumber) disconnected reason=\(reason) durationMs=\(elapsedMs) rxBytes=\(receivedBytes) processedTxBytes=\(processedBytes)")
        onClientDisconnected?()
    }

    private func receiveLoop(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self, self.connection === conn else { return }
            if let data, !data.isEmpty {
                self.receivedBytes += data.count
                self.rxBuffer.append(data)
                self.processBuffer()
            }
            if let error {
                self.teardown(conn, reason: "receive failed: \(error)")
            } else if isComplete {
                self.teardown(conn, reason: "peer EOF")
            } else if self.connection === conn {
                self.receiveLoop(conn)
            }
        }
    }

    private func processBuffer() {
        while rxBuffer.count >= 5 {
            let type = rxBuffer[rxBuffer.startIndex]
            let len = Int(rxBuffer[rxBuffer.startIndex + 1]) << 24
                | Int(rxBuffer[rxBuffer.startIndex + 2]) << 16
                | Int(rxBuffer[rxBuffer.startIndex + 3]) << 8
                | Int(rxBuffer[rxBuffer.startIndex + 4])
            // Client traffic is small JSON, never video or audio. Bound malformed frames.
            guard len <= 1 << 20 else {
                if let conn = connection { teardown(conn, reason: "invalid incoming frame length=\(len)") }
                return
            }
            guard rxBuffer.count >= 5 + len else { break }
            let payload = rxBuffer.subdata(in: rxBuffer.startIndex + 5 ..< rxBuffer.startIndex + 5 + len)
            rxBuffer.removeSubrange(rxBuffer.startIndex ..< rxBuffer.startIndex + 5 + len)
            handleFrame(type: type, payload: payload)
        }
    }

    private func handleFrame(type: UInt8, payload: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            log.write("session=\(sessionNumber) unparseable frame type=\(type) bytes=\(payload.count)")
            return
        }
        switch type {
        case 0x00:
            if clientHello == nil { log.write("session=\(sessionNumber) first control received") }
            clientHello = json
            onControl?(json)
        case 0x02:
            onInput?(json)
        case 0x03:
            onClientStats?(json)
        default:
            break
        }
    }

    // MARK: - Sending

    func sendControl(_ json: [String: Any]) {
        send(type: 0x00, payload: (try? JSONSerialization.data(withJSONObject: json)) ?? Data())
    }

    func sendVideo(_ annexB: Data) {
        send(type: 0x01, payload: annexB)
    }

    /// Raw PCM 16-bit LE 48kHz stereo chunk.
    func sendAudio(_ pcm: Data) {
        send(type: 0x04, payload: pcm)
    }

    func sendStats(_ json: [String: Any]) {
        send(type: 0x03, payload: (try? JSONSerialization.data(withJSONObject: json)) ?? Data())
    }

    private func send(type: UInt8, payload: Data) {
        queue.async { [weak self] in
            guard let self, let conn = self.connection, conn.state == .ready else { return }
            var frame = Data(capacity: payload.count + 5)
            frame.append(type)
            frame.append(UInt8((payload.count >> 24) & 0xFF))
            frame.append(UInt8((payload.count >> 16) & 0xFF))
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
            frame.append(payload)
            let count = frame.count
            conn.send(content: frame, completion: .contentProcessed { [weak self, weak conn] error in
                guard let self, let conn else { return }
                self.queue.async {
                    guard self.connection === conn else { return }
                    if let error {
                        self.teardown(conn, reason: "send failed type=\(type): \(error)")
                    } else {
                        self.processedBytes += count
                    }
                }
            })
        }
    }

    var hasClient: Bool {
        queue.sync { connection?.state == .ready }
    }
}
