import Foundation
import CoreGraphics

// Exercise the production Pipeline without displays, TCC, sockets or a host app.
final class DisplayCapturer {
    var onFrame: ((Int, Double) -> Void)?
    var onAudio: ((Data) -> Void)?
    var fail = false
    init(displayID: CGDirectDisplayID) {}
    func start(fps: Int, pixelWidth: Int, pixelHeight: Int) async throws {
        if fail { throw Failure.expected }
        onFrame?(1, 0) // A capture can deliver before start returns.
    }
    func stop() {}
}
enum Failure: Error { case expected }
final class VideoEncoder {
    var onPacket: ((Data, Double, Bool) -> Void)?
    var codec: VideoCodec?
    var fail = false
    func start(width: Int, height: Int, fps: Int, bitrateBps: Int, codec: VideoCodec = .hevc) throws {
        if fail { throw Failure.expected }
        self.codec = codec
    }
    func encode(frame: Int, forceKeyframe: Bool) { onPacket?(Data([1]), 0, true) }
    func stop() { codec = nil }
    func setBitrate(_ bps: Int) {}
}
final class FrameServer {
    var videos = 0
    var currentSession = 1
    var controls: [[String: Any]] = []
    var onControl: (([String: Any]) -> Void)?
    var onInput: (([String: Any]) -> Void)?
    var onClientStats: (([String: Any]) -> Void)?
    var onClientConnected: (() -> Void)?
    var onClientDisconnected: (() -> Void)?
    // Mic route hooks mirror the real FrameServer so the extracted wireServer
    // extension compiles unchanged; the harness never drives 0x07.
    var onMicPCM: ((Data) -> Void)?
    var onMicNegotiated: ((Bool) -> Void)?
    func sendControl(_ json: [String: Any], forSession session: Int? = nil) {
        if session == nil || session == currentSession { controls.append(json) }
    }
    func sendTiming(_ json: [String: Any]) {}
    func sendVideo(_ data: Data) { videos += 1 }
    func sendAudio(_ data: Data) {}
}
final class HostLog {
    static let shared = HostLog()
    func write(_ message: String) {}
}
@main struct CodecPipelineTests {
    static func main() {
        let pipeline = Pipeline(displayID: 0), server = FrameServer()
        var acknowledgements = 0
        func start(_ codec: VideoCodec) -> Bool {
            pipeline.start(server: server, width: 320, height: 240, fps: 30, bitrateBps: 2_000_000,
                           codec: codec, beforeStreaming: {
                precondition(pipeline.encoder.codec == codec, "ack must describe prepared encoder")
                precondition(server.videos == 0, "capture must not publish before ack")
                acknowledgements += 1
            })
        }
        precondition(start(.h264))
        precondition(acknowledgements == 1)
        pipeline.capturer.onFrame?(1, 0)
        precondition(server.videos == 1)
        server.videos = 0
        precondition(start(.hevc), "codec change reconnect must reconfigure")
        precondition(pipeline.encoder.codec == .hevc && acknowledgements == 2)
        pipeline.reset()
        pipeline.encoder.fail = true
        precondition(!start(.h264))
        precondition(acknowledgements == 2, "failed encoder cannot acknowledge success")
        pipeline.encoder.fail = false
        pipeline.capturer.fail = true
        precondition(!start(.h264))
        precondition(acknowledgements == 2, "failed capture cannot acknowledge success")
        pipeline.capturer.fail = false
        precondition(start(.h264), "partial failure must allow retry")
        pipeline.reset()
        print("PASS pipeline codec reconfiguration, ack before media, encoder/capture failure and retry")
    }
}
