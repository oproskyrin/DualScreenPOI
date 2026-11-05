import Foundation
import CoreGraphics
import CGVirtualDisplayShim

// DualScreenHost — turns an Android tablet into a true extended display.
//
// Pipeline: CGVirtualDisplay (private API) -> ScreenCaptureKit ->
// VideoToolbox HEVC (hardware, realtime) -> TCP (USB via `adb reverse`,
// or Wi-Fi). Touch input flows back as JSON and is injected with CGEvent.

let args = CommandLine.arguments
setbuf(stdout, nil) // unbuffered logs even through pipes
func argValue(_ name: String, _ fallback: String) -> String {
    if let i = args.firstIndex(of: name), i + 1 < args.count { return args[i + 1] }
    return fallback
}

let width = Int(argValue("--width", "2944"))!
let height = Int(argValue("--height", "1840"))!
let fps = Int(argValue("--fps", "120"))!
let bitrateMbps = Int(argValue("--bitrate", "80"))!
let port = UInt16(argValue("--port", "7381"))!
let hidpi = args.contains("--no-hidpi") ? false : true
// First rate is the active display mode (max first), rest are selectable.
let rates: [Double] = [144, 120, 90, 60]

print("[ds] DualScreenHost starting: \(width)x\(height)@\(fps)fps, \(bitrateMbps) Mbps, port \(port), hidpi=\(hidpi)")

// 1. Screen Recording permission (TCC). Prompts on first run.
if !CGPreflightScreenCaptureAccess() {
    print("[ds] requesting Screen Recording permission…")
    _ = CGRequestScreenCaptureAccess()
}

// 2. Create the virtual extended display (must run on main thread — we are).
let displayID = rates.withUnsafeBufferPointer { ratesBuf in
    vd_create_display(UInt32(width), UInt32(height),
                      ratesBuf.baseAddress, ratesBuf.count,
                      hidpi,
                      0x041A, 0x371F, 0x2023, // Lenovo-ish vendor/product (arbitrary, stable)
                      "Xiaoxin Pad Pro 12.7")
}
guard displayID != 0 else {
    FileHandle.standardError.write("FATAL: virtual display creation failed\n".data(using: .utf8)!)
    exit(1)
}
print("[ds] virtual display created: id=\(displayID)")

// 3. Force "extend" if macOS auto-mirrored the new display.
if CGDisplayIsInMirrorSet(displayID) != 0 {
    var config: CGDisplayConfigRef?
    if CGBeginDisplayConfiguration(&config) == CGError.success {
        let mainBounds = CGDisplayBounds(CGMainDisplayID())
        CGConfigureDisplayOrigin(config, displayID, Int32(mainBounds.maxX) + 1, 0)
        _ = CGCompleteDisplayConfiguration(config, .permanently)
        print("[ds] unmirrored: placed to the right of the main display")
    }
}

let injector = InputInjector(displayID: displayID)

// 4. Capture + encode pipeline, started on first client hello.
final class Pipeline {
    let capturer: DisplayCapturer
    let encoder = VideoEncoder()
    private var started = false
    private var encoderReady = false
    private let lock = NSLock()
    private var fpsWindowStart = Date()
    private var fpsCount = 0
    private var dbgPackets = 0
    private var dbgKeysDumped = 0

    /// Walks Annex-B NALs and prints their HEVC types (32=VPS, 33=SPS, 34=PPS).
    func dumpNalTypes(_ data: Data) {
        var types: [Int] = []
        var i = data.startIndex
        while i < data.endIndex - 4 {
            if data[i] == 0, data[i + 1] == 0, data[i + 2] == 0, data[i + 3] == 1 {
                if i + 4 < data.endIndex {
                    types.append(Int((data[i + 4] & 0x7E) >> 1))
                }
                i += 4
            } else if data[i] == 0, data[i + 1] == 0, data[i + 2] == 1 {
                if i + 3 < data.endIndex {
                    types.append(Int((data[i + 3] & 0x7E) >> 1))
                }
                i += 3
            } else {
                i += 1
            }
        }
        print("[ds] keyframe NAL types: \(types)")
        let head = data.prefix(24).map { String(format: "%02x", $0) }.joined(separator: " ")
        print("[ds] keyframe head: \(head)")
    }

    init(displayID: CGDirectDisplayID) {
        capturer = DisplayCapturer(displayID: displayID)
        capturer.onFrame = { [weak self] buffer, _ in
            guard let self else { return }
            if self.encoderReady {
                self.encoder.encode(frame: buffer)
            }
        }
    }

    func start(server: FrameServer, width: Int, height: Int, fps: Int, bitrateBps: Int) {
        lock.lock(); defer { lock.unlock() }
        guard !started else { return }
        started = true

        encoder.onPacket = { [weak server] data, _, isKey in
            guard let server else { return }
            self.dbgPackets += 1
            if self.dbgPackets <= 5 {
                print("[ds] packet#\(self.dbgPackets): \(data.count) bytes, key=\(isKey)")
            }
            if isKey && self.dbgKeysDumped < 2 {
                self.dbgKeysDumped += 1
                self.dumpNalTypes(data)
            }
            server.sendVideo(data)
            self.noteFrameSent()
        }

        let sem = DispatchSemaphore(value: 0)
        Task.detached { [weak self] in
            guard let self else { sem.signal(); return }
            do {
                try await self.capturer.start(fps: fps, pixelWidth: width, pixelHeight: height)
                try self.encoder.start(width: width, height: height, fps: fps, bitrateBps: bitrateBps)
                self.encoderReady = true
                print("[ds] capture+encode running at \(width)x\(height)@\(fps)")
            } catch {
                print("[ds] pipeline error: \(error)")
            }
            sem.signal()
        }
        sem.wait()
    }

    func noteFrameSent() {
        fpsCount += 1
        let now = Date()
        if now.timeIntervalSince(fpsWindowStart) >= 5 {
            let f = Double(fpsCount) / now.timeIntervalSince(fpsWindowStart)
            print(String(format: "[ds] sending %.1f fps", f))
            fpsWindowStart = now
            fpsCount = 0
        }
    }
}

let server = FrameServer()
let pipeline = Pipeline(displayID: displayID)

server.onControl = { hello in
    guard (hello["magic"] as? String) == "DSXP" else { return }
    let clientW = hello["width"] as? Int ?? width
    let clientH = hello["height"] as? Int ?? height
    let clientHz = hello["maxRefresh"] as? Int ?? 144
    print("[ds] tablet says hello: \(clientW)x\(clientH), panel \(clientHz) Hz")

    pipeline.start(server: server, width: width, height: height, fps: fps,
                   bitrateBps: bitrateMbps * 1_000_000)
    server.sendControl([
        "ok": true,
        "width": width,
        "height": height,
        "fps": fps,
        "bitrate": bitrateMbps * 1_000_000,
        "codec": "hevc",
        "displayID": Int(displayID),
    ])
    injector.refreshBounds()
}

server.onInput = { json in
    injector.handle(json)
}
server.onClientDisconnected = {
    print("[ds] client disconnected; display stays, pipeline idles")
}

do {
    try server.start(port: port)
} catch {
    FileHandle.standardError.write("FATAL: cannot listen on port \(port): \(error)\n".data(using: .utf8)!)
    vd_release_display()
    exit(1)
}

// 5. Clean shutdown on Ctrl-C (removes the virtual display).
let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
signal(SIGINT, SIG_IGN)
signalSource.setEventHandler {
    print("\n[ds] shutting down…")
    pipeline.capturer.stop()
    pipeline.encoder.stop()
    vd_release_display()
    exit(0)
}
signalSource.resume()

print("[ds] ready. Connect the tablet (USB: adb reverse tcp:\(port) tcp:\(port); Wi-Fi: this Mac's IP).")
RunLoop.main.run()
