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

let width0 = Int(argValue("--width", "2944"))!
let height0 = Int(argValue("--height", "1840"))!
let fps = Int(argValue("--fps", "120"))!
let bitrateMbps = Int(argValue("--bitrate", "80"))!
let port = UInt16(argValue("--port", "7381"))!
let hidpi = args.contains("--no-hidpi") ? false : true
// --mirror: stream the main display as-is (no virtual display created)
let mirror = args.contains("--mirror")
// --logical WxH (extend mode): pick the display's logical resolution.
// Bigger = sharper stream (less upscaling to 2944x1840) but smaller UI.
// 1472x920 = comfy default; 2944x1840 = pixel-perfect 1:1.
let logicalArg = argValue("--logical", "")
// First rate is the active display mode (max first), rest are selectable.
let rates: [Double] = [144, 120, 90, 60]

print("[ds] DualScreenHost starting: mode=\(mirror ? "mirror" : "extend") \(width0)x\(height0)@\(fps)fps, \(bitrateMbps) Mbps, port \(port), hidpi=\(hidpi)")

var displayID: CGDirectDisplayID = 0
var width = width0
var height = height0

if mirror {
    // Mirror mode: capture the main display, no virtual display at all.
    displayID = CGMainDisplayID()
    // Apple Silicon built-in panels hide their 2x backing: CG reports the
    // logical size as "pixels" (e.g. 1408x881). Request 2x from SCK — it
    // caps at the real native backing (2816x1762), giving a retina mirror.
    let b = CGDisplayBounds(displayID)
    let pxW = CGDisplayPixelsWide(displayID)
    let pxH = CGDisplayPixelsHigh(displayID)
    if pxW <= Int(b.width) + 1 && pxH <= Int(b.height) + 1 {
        width = pxW * 2
        height = pxH * 2
    } else {
        width = pxW
        height = pxH
    }
    print("[ds] mirroring main display: \(width)x\(height) px (id=\(displayID))")
} else {
// 1. Screen Recording permission (TCC). Prompts on first run.
if !CGPreflightScreenCaptureAccess() {
    print("[ds] requesting Screen Recording permission…")
    _ = CGRequestScreenCaptureAccess()
}

// 2. Create the virtual extended display (must run on main thread — we are).
let createdID = rates.withUnsafeBufferPointer { ratesBuf in
    vd_create_display(UInt32(width), UInt32(height),
                      ratesBuf.baseAddress, ratesBuf.count,
                      hidpi,
                      0x041A, 0x371F, 0x2023, // Lenovo-ish vendor/product (arbitrary, stable)
                      "Xiaoxin Pad Pro 12.7")
}
guard createdID != 0 else {
    FileHandle.standardError.write("FATAL: virtual display creation failed\n".data(using: .utf8)!)
    exit(1)
}
displayID = createdID
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

// 3b. Logical resolution: with hidpi on the shim declares half-size modes
// (1472x920 default). --logical WxH overrides with any ladder mode —
// closer to native = sharper stream (SCK upscales the backing to 2944x1840).
if !mirror {
    Thread.sleep(forTimeInterval: 0.5) // let WindowServer settle
    if let modes = CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode] {
        var targetW = width / 2, targetH = height / 2
        if !logicalArg.isEmpty {
            let parts = logicalArg.split(whereSeparator: { $0 == "x" || $0 == "X" })
            if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) {
                targetW = w; targetH = h
            } else {
                print("[ds] bad --logical \"\(logicalArg)\" (want WxH); using default")
            }
        }
        // closest ladder mode to the requested logical size
        let want = modes.min {
            let d1 = abs($0.width - targetW) + abs($0.height - targetH)
            let d2 = abs($1.width - targetW) + abs($1.height - targetH)
            return d1 == d2 ? $0.refreshRate > $1.refreshRate : d1 < d2
        }
        if let want {
            let err = CGDisplaySetDisplayMode(displayID, want, nil)
            let b = CGDisplayBounds(displayID)
            print("[ds] logical \(want.width)x\(want.height)@\(Int(want.refreshRate)): err=\(err.rawValue), " +
                  "bounds=\(Int(b.width))x\(Int(b.height)) pts, mode px=\(want.pixelWidth)x\(want.pixelHeight)")
        } else {
            print("[ds] no modes available for logical selection")
        }
    }
}
} // end extend-mode setup

let injector = InputInjector(displayID: displayID)
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
        "mirror": mirror,
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
