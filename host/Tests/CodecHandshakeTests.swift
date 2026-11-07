import Foundation
import CoreGraphics

// Only dependencies are replaced. The three handshake methods are extracted
// unchanged from main.swift by test-host-codec.sh, so no app/TCC is started.
final class HandshakeInjector {
    func reset() {}
    func refreshBounds() {}
    func handle(_ json: [String: Any]) {}
}
final class HostApp {
    enum Mode { case mirror, extend }
    struct Settings {
        var panelW = 320, panelH = 240, fps = 30, bitrateMbps = 2
        var mode = Mode.mirror
        var logicalW = 320, logicalH = 240
    }
    let server = FrameServer()
    var settings = Settings()
    var pipeline: Pipeline? = Pipeline(displayID: 0)
    var negotiatedSession: (id: Int, codec: VideoCodec)?
    var injector: HandshakeInjector? = HandshakeInjector()
    let clockSync = ClockSyncEcho(), inputProbe = InputProbeEcho()
    var streamW = 320, streamH = 240
    var displayID: CGDirectDisplayID = 0
    func handleCommand(_ cmd: String, _ json: [String: Any]) {}
    func adaptBitrate(clientStats: [String: Any]) {}
}
@main struct CodecHandshakeTests {
    static func main() {
        let host = HostApp()
        host.wireServer()
        func hello(_ fields: [String: Any]) -> [String: Any] {
            let count = host.server.controls.count
            host.server.onControl?(fields.merging(["magic": "DSXP"]) { a, _ in a })
            let deadline = Date().addingTimeInterval(3)
            while host.server.controls.count == count && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            precondition(host.server.controls.count == count + 1, "one ack per hello")
            return host.server.controls.last!
        }
        precondition(hello([:])["codec"] as? String == "hevc")
        let avc = hello(["codecs": ["hevc", "h264"], "preferredCodec": "h264"])
        precondition(avc["ok"] as? Bool == true && avc["codec"] as? String == "h264")
        precondition(host.pipeline?.encoder.codec == .h264)
        let rejected = hello(["codecs": ["av1"]])
        precondition(rejected["ok"] as? Bool == false && rejected["error"] is String && rejected["codec"] == nil)
        precondition(host.pipeline?.encoder.codec == nil)
        host.pipeline?.encoder.fail = true
        let failed = hello(["codecs": ["h264"]])
        precondition(failed["ok"] as? Bool == false && failed["codec"] == nil)
        host.pipeline?.encoder.fail = false
        precondition(hello([:])["codec"] as? String == "hevc")
        host.pipeline?.reset()
        print("PASS production hello/ack wiring: legacy HEVC, AVC selection, no-common rejection, startup failure, retry")
    }
}
