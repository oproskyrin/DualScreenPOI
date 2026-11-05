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

    /// JSON control messages from the tablet (the hello first).
    var onControl: (([String: Any]) -> Void)?
    /// JSON input events from the tablet.
    var onInput: (([String: Any]) -> Void)?
    var onClientConnected: (() -> Void)?
    var onClientDisconnected: (() -> Void)?

    private var rxBuffer = Data()

    func start(port: UInt16 = FrameServer.defaultPort) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            self.queue.async {
                // single-client for now: drop previous connection
                if let old = self.connection {
                    old.cancel()
                    self.connection = nil
                }
                self.accept(conn)
            }
        }
        self.listener = listener
        listener.start(queue: queue)
        print("[server] listening on TCP:\(port)")
    }

    private func accept(_ conn: NWConnection) {
        connection = conn
        clientHello = nil
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                print("[server] client connected: \(conn.endpoint)")
                self.onClientConnected?()
                self.receiveLoop(conn)
            case .failed(let e):
                print("[server] connection failed: \(e)")
                self.teardown()
            case .cancelled:
                self.teardown()
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func teardown() {
        if connection != nil {
            connection = nil
            rxBuffer.removeAll(keepingCapacity: true)
            print("[server] client gone")
            onClientDisconnected?()
        }
    }

    private func receiveLoop(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.rxBuffer.append(data)
                self.processBuffer()
            }
            if error == nil && !isComplete && self.connection === conn {
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
            guard rxBuffer.count >= 5 + len else { break }
            let payload = rxBuffer.subdata(in: rxBuffer.startIndex + 5 ..< rxBuffer.startIndex + 5 + len)
            rxBuffer.removeSubrange(rxBuffer.startIndex ..< rxBuffer.startIndex + 5 + len)
            handleFrame(type: type, payload: payload)
        }
    }

    private func handleFrame(type: UInt8, payload: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return }
        switch type {
        case 0x00:
            clientHello = json
            onControl?(json)
        case 0x02:
            onInput?(json)
        case 0x03:
            if let f = json["fps"] { print("[server] client stats: \(f) fps") }
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
            conn.send(content: frame, completion: .contentProcessed { _ in })
        }
    }

    var hasClient: Bool {
        queue.sync { connection?.state == .ready }
    }
}
