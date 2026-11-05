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
// 1 = UI в нативных пикселях (мелко, максимум места),
// 2 = Retina @2x: "looks like" 1472×920, текст резкий (по умолчанию)
let scale = Int(argValue("--scale", "2"))!
// First rate is the active display mode (max first), rest are selectable.
let rates: [Double] = [144, 120, 90, 60]

print("[ds] DualScreenHost starting: \(width)x\(height)@\(fps)fps, \(bitrateMbps) Mbps, port \(port), hidpi=\(hidpi), scale=\(scale)")

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

// 3. Position the virtual display right of the main display with aligned
// top edge — also forces "extend" if macOS auto-mirrored the new display.
do {
    var config: CGDisplayConfigRef?
    if CGBeginDisplayConfiguration(&config) == CGError.success {
        let mainBounds = CGDisplayBounds(CGMainDisplayID())
        CGConfigureDisplayOrigin(config, displayID, Int32(mainBounds.maxX), Int32(mainBounds.minY))
        _ = CGCompleteDisplayConfiguration(config, .permanently)
        print("[ds] positioned at (\(Int(mainBounds.maxX)), \(Int(mainBounds.minY))) — right of main")
    }
    if CGDisplayIsInMirrorSet(displayID) != 0 {
        print("[ds] warning: still in mirror set")
    }
}

let injector = InputInjector(displayID: displayID)

// 3b. HiDPI: the shim declares half-size POINTS modes when hidpi is on.
// macOS's synthesized ladder usually wins mode selection, so force our
// declared mode; with hiDPI=1 the backing store should be 2x the points.
if hidpi {
    Thread.sleep(forTimeInterval: 0.5) // let WindowServer settle
    if let modes = CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode] {
        print("[ds] active: \(CGDisplayBounds(displayID).width)x\(CGDisplayBounds(displayID).height) pts")
        let want = modes.first {
            $0.width == width / 2 && $0.height == height / 2 &&
            abs($0.refreshRate - rates[0]) < 1.0
        }
        if let want {
            let err = CGDisplaySetDisplayMode(displayID, want, nil)
            let b = CGDisplayBounds(displayID)
            print("[ds] setDisplayMode(\(width / 2)x\(height / 2)): err=\(err.rawValue), " +
                  "bounds=\(Int(b.width))x\(Int(b.height)) pts")
        } else {
            print("[ds] half-res mode not found in ladder")
        }
    }
}

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
    private var forceKeyFrames = 0
    private var lastRestart = Date.distantPast

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
                let force = self.forceKeyFrames > 0
                if force { self.forceKeyFrames -= 1 }
                self.encoder.encode(frame: buffer, forceKeyframe: force)
            }
        }
    }

    /// A (re)connected client needs fresh frames and an IDR: restart the
    /// capture (guarantees a frame even for static content) and force
    /// keyframes for the first few encoded packets.
    func kickAfterReconnect() {
        lock.lock(); defer { lock.unlock() }
        guard started, encoderReady else { return }
        guard Date().timeIntervalSince(lastRestart) > 1.0 else { return }
        lastRestart = Date()
        forceKeyFrames = 3
        let capt = capturer
        let w = self.captureW, h = self.captureH, f = self.captureFps
        Task.detached {
            capt.stop()
            try? await capt.start(fps: f, pixelWidth: w, pixelHeight: h)
        }
    }

    private var captureW = 0, captureH = 0, captureFps = 0

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

        capturer.onAudio = { [weak server] pcm in
            server?.sendAudio(pcm)
        }

        let sem = DispatchSemaphore(value: 0)
        captureW = width; captureH = height; captureFps = fps
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
    pipeline.kickAfterReconnect()
    server.sendControl([
        "ok": true,
        "width": width,
        "height": height,
        "fps": fps,
        "bitrate": bitrateMbps * 1_000_000,
        "codec": "hevc",
        "audio": "pcm16",
        "audioRate": 48000,
        "audioChannels": 2,
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

// 5. USB autopilot: when a tablet is plugged in and nobody is connected,
// set up `adb reverse` and launch the client automatically.
final class UsbWatchdog {
    private let adbPath: String
    private let server: FrameServer
    private var lastLaunch = Date.distantPast

    init?(server: FrameServer) {
        let candidates = ["/opt/homebrew/bin/adb", "/usr/local/bin/adb", "/usr/bin/adb"]
        guard let adb = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            print("[usb] adb not found; automatic USB flow disabled")
            return nil
        }
        adbPath = adb
        self.server = server
    }

    func run(_ arguments: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: adbPath)
        p.arguments = arguments
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit() } catch { return nil }
        guard p.terminationStatus == 0 else { return nil }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }

    func tick() {
        guard !server.hasClient else { return }
        guard Date().timeIntervalSince(lastLaunch) > 8 else { return }
        guard let out = run(["devices"]),
              out.contains("\tdevice") else { return } // authorized USB device present
        lastLaunch = Date()
        print("[usb] tablet on USB: wiring adb reverse + launching client")
        _ = run(["reverse", "tcp:\(port)", "tcp:\(port)"])
        _ = run(["shell", "am", "start", "-n", "com.oleg.dualscreen/.MainActivity",
                 "--ez", "autoconnect", "true"])
    }
}

if let usb = UsbWatchdog(server: server) {
    let usbTimer = Timer(timeInterval: 2, repeats: true) { _ in usb.tick() }
    RunLoop.main.add(usbTimer, forMode: .common)
}

// 6. Clean shutdown on Ctrl-C (removes the virtual display).
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
