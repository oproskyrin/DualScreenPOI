import Foundation
import AppKit
import CoreGraphics
import CGVirtualDisplayShim

// DualScreenHost — turns an Android tablet into a second display for macOS.
//
// Pipeline: CGVirtualDisplay (private API, extend) or the main display
// (mirror) -> ScreenCaptureKit -> VideoToolbox HEVC/H264 (realtime) ->
// TCP (USB via `adb reverse`, Wi-Fi with mDNS). Touch input flows back as
// JSON and is injected with CGEvent. Runs as a menu bar app; modes and
// quality are switchable live from the menu or from the tablet.

let args = CommandLine.arguments
setbuf(stdout, nil) // unbuffered logs even through pipes
func argValue(_ name: String, _ fallback: String) -> String {
    if let i = args.firstIndex(of: name), i + 1 < args.count { return args[i + 1] }
    return fallback
}

// MARK: - Pipeline

final class Pipeline {
    let capturer: DisplayCapturer
    let encoder = VideoEncoder()
    /// Pairs each submitted frame's SCK arrival time (cap) with the uptime ns
    /// its encoded packet is emitted (enc) for the 0x05 timing sidecar.
    let timing = TimingFIFO()
    private var started = false
    private var encoderReady = false
    private(set) var codec: VideoCodec?
    private let lock = NSLock()
    private var fpsWindowStart = Date()
    private var fpsCount = 0
    private var dbgPackets = 0
    private var dbgKeysDumped = 0
    private var forceKeyFrames = 0
    private var lastRestart = Date.distantPast
    private(set) var currentFps: Double = 0

    /// Prints negotiated-codec NAL types (HEVC: 32/33/34, AVC: 7/8).
    func dumpNalTypes(_ data: Data) {
        var types: [Int] = []
        var i = data.startIndex
        while i < data.endIndex - 4 {
            if data[i] == 0, data[i + 1] == 0, data[i + 2] == 0, data[i + 3] == 1 {
                if i + 4 < data.endIndex { types.append(codec == .h264 ? Int(data[i + 4] & 31) : Int((data[i + 4] & 0x7E) >> 1)) }
                i += 4
            } else if data[i] == 0, data[i + 1] == 0, data[i + 2] == 1 {
                if i + 3 < data.endIndex { types.append(codec == .h264 ? Int(data[i + 3] & 31) : Int((data[i + 3] & 0x7E) >> 1)) }
                i += 3
            } else {
                i += 1
            }
        }
        print("[ds] keyframe NAL types: \(types)")
    }

    init(displayID: CGDirectDisplayID) {
        capturer = DisplayCapturer(displayID: displayID)
        capturer.onFrame = { [weak self] buffer, _ in
            guard let self else { return }
            if self.encoderReady {
                let force = self.forceKeyFrames > 0
                if force { self.forceKeyFrames -= 1 }
                self.timing.push(capNs: Double(DispatchTime.now().uptimeNanoseconds))
                self.encoder.encode(frame: buffer, forceKeyframe: force)
            }
        }
    }

    /// Attaches output sinks. Called on every (re)configuration.
    func wire(server: FrameServer) {
        encoder.onPacket = { [weak server] data, _, isKey in
            guard let server else { return }
            self.dbgPackets += 1
            if self.dbgPackets <= 3 {
                print("[ds] packet#\(self.dbgPackets): \(data.count) bytes, key=\(isKey)")
            }
            if isKey && self.dbgKeysDumped < 1 {
                self.dbgKeysDumped += 1
                self.dumpNalTypes(data)
            }
            if let t = self.timing.pop(encNs: Double(DispatchTime.now().uptimeNanoseconds)) {
                server.sendTiming(["seq": t.seq, "cap": t.cap, "enc": t.enc])
            }
            server.sendVideo(data)
            self.noteFrameSent()
        }
        capturer.onAudio = { [weak server] pcm in
            server?.sendAudio(pcm)
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
            do {
                try await capt.start(fps: f, pixelWidth: w, pixelHeight: h)
            } catch {
                HostLog.shared.write("capture restart failed: \(error)")
            }
        }
    }

    private var captureW = 0, captureH = 0, captureFps = 0

    @discardableResult
    func start(server: FrameServer, width: Int, height: Int, fps: Int, bitrateBps: Int,
               codec: VideoCodec = .hevc, beforeStreaming: () -> Void) -> Bool {
        if started && self.codec != codec { reset() }
        lock.lock(); defer { lock.unlock() }
        if started { beforeStreaming(); return encoderReady }
        self.codec = codec
        wire(server: server)

        let sem = DispatchSemaphore(value: 0)
        captureW = width; captureH = height; captureFps = fps
        Task.detached { [weak self] in
            guard let self else { sem.signal(); return }
            do {
                try self.encoder.start(width: width, height: height, fps: fps, bitrateBps: bitrateBps, codec: codec)
                try await self.capturer.start(fps: fps, pixelWidth: width, pixelHeight: height)
                self.started = true
                print("[ds] capture+encode running at \(width)x\(height)@\(fps)")
                HostLog.shared.write("pipeline running width=\(width) height=\(height) requestedFps=\(fps)")
            } catch {
                print("[ds] pipeline error: \(error)")
                HostLog.shared.write("pipeline start failed: \(error)")
                self.capturer.stop()
                self.encoder.stop()
                self.codec = nil
            }
            sem.signal()
        }
        sem.wait()
        guard started else { return false }
        beforeStreaming()
        encoderReady = true
        return true
    }

    /// Full stop so a new start() can reconfigure (mode/fps/bitrate switch).
    func reset() {
        lock.lock(); defer { lock.unlock() }
        guard started else { return }
        started = false
        encoderReady = false
        codec = nil
        timing.reset() // stale caps must not pair with a new configuration's packets
        let capt = capturer
        capturer.onAudio = nil
        encoder.onPacket = nil
        encoder.stop()
        // Drop the capture's stream reference now, before releasing a virtual
        // display during application termination. stopCapture itself is async.
        capt.stop()
    }

    /// Live bitrate change without touching the running pipeline.
    func setBitrate(_ bps: Int) {
        lock.lock(); defer { lock.unlock() }
        guard encoderReady else { return }
        encoder.setBitrate(bps)
    }

    private func noteFrameSent() {
        fpsCount += 1
        let now = Date()
        if now.timeIntervalSince(fpsWindowStart) >= 2 {
            currentFps = Double(fpsCount) / now.timeIntervalSince(fpsWindowStart)
            print(String(format: "[ds] sending %.1f fps", currentFps))
            fpsWindowStart = now
            fpsCount = 0
        }
    }
}

// MARK: - HostApp

final class HostApp {
    enum Mode: String { case extend, mirror }

    struct Settings {
        var mode: Mode
        var logicalW: Int
        var logicalH: Int
        var panelW: Int
        var panelH: Int
        var fps: Int
        var bitrateMbps: Int
        var port: UInt16
        var hidpi: Bool
    }

    private(set) var settings: Settings
    let server = FrameServer()

    private(set) var displayID: CGDirectDisplayID = 0
    private(set) var streamW = 0
    private(set) var streamH = 0
    private var virtualCreated = false
    private var injector: InputInjector?
    private(set) var pipeline: Pipeline?
    private var negotiatedSession: (id: Int, codec: VideoCodec)?
    private var menuBar: MenuBar?
    private let terminationPreparation = TerminationPreparation()
    private let audioPresence = AudioDevicePresence()
    /// NTP-lite echo of the client's last t1 (see TimingCoordinator.swift).
    private let clockSync = ClockSyncEcho()
    /// Raw echo of the last input ts probe; host does no offset math.
    private let inputProbe = InputProbeEcho()
    private var timers: [Timer] = []
    var updater: AppUpdater?
    private let arrangement = DisplayArrangement()
    private var signalSources: [DispatchSourceSignal] = []
    private let rates: [Double] = [144, 120, 90, 60]

    // adaptive bitrate
    private var maxBitrateBps = 0
    private var currentBitrateBps = 0
    private var goodWindows = 0
    private var lastAdjust = Date.distantPast

    init(settings: Settings) {
        self.settings = settings
    }

    func run() {
        HostLog.shared.write("host starting mode=\(settings.mode.rawValue) requestedFps=\(settings.fps)")
        // Detect an old CLI host before asking for permissions or creating a display.
        wireServer()
        do {
            try server.start(port: settings.port)
        } catch {
            let message = "Не удалось открыть порт \(settings.port). Возможно, уже работает другой DualScreenHost (в том числе старая CLI-версия). Завершите его и откройте DualScreen снова.\n\(error)"
            FileHandle.standardError.write(Data((message + "\n").utf8))
            if Bundle.main.bundleURL.pathExtension == "app" {
                let alert = NSAlert(); alert.messageText = "DualScreen уже запущен или порт занят"
                alert.informativeText = message; alert.runModal()
            }
            prepareForTermination()
            exit(1)
        }
        audioPresence.start()
        let inputAccess = CGPreflightPostEventAccess()
        HostLog.shared.write("input permission granted=\(inputAccess)")
        if !inputAccess { _ = CGRequestPostEventAccess() }
        arrangement.onChange = { [weak self] in self?.injector?.refreshBounds() }
        if !CGPreflightScreenCaptureAccess() {
            print("[ds] requesting Screen Recording permission…")
            _ = CGRequestScreenCaptureAccess()
        }

        applyMode()

        // periodic stats to the tablet
        let statsTimer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.sendStats()
        }
        RunLoop.main.add(statsTimer, forMode: .common)
        timers.append(statsTimer)

        // USB autopilot: plug the cable -> everything connects by itself
        if let usb = UsbWatchdog(server: server, port: settings.port) {
            let usbTimer = Timer(timeInterval: 2, repeats: true) { _ in usb.tick() }
            RunLoop.main.add(usbTimer, forMode: .common)
            timers.append(usbTimer)
        }

        // Strong reference: the status item itself is retained by the system
        // (icon stays), but the menu items' targets die with this object —
        // an unreferenced MenuBar shows a dead, greyed-out menu.
        menuBar = MenuBar(host: self)
        setupSignalHandler()
        print("[ds] ready (menu bar icon active)")
        // NSApp.run() — not RunLoop.main.run(): menu tracking in the status
        // bar only works inside the real NSApplication event loop. Timers
        // added to the main RunLoop keep firing either way.
        NSApplication.shared.run()
    }

    // MARK: mode / display lifecycle

    /// Teardown + setup for the current settings. Safe to call repeatedly.
    func applyMode() {
        injector?.reset()
        injector = nil
        arrangement.detach()
        pipeline?.reset()
        pipeline = nil
        if virtualCreated {
            vd_release_display()
            virtualCreated = false
            displayID = 0
        }

        switch settings.mode {
        case .mirror:
            displayID = CGMainDisplayID()
            // Apple Silicon built-ins hide their 2x backing (CG reports the
            // logical size as "pixels"). Request 2x from SCK — it caps at the
            // real native backing, giving a retina mirror.
            let b = CGDisplayBounds(displayID)
            let pxW = CGDisplayPixelsWide(displayID)
            let pxH = CGDisplayPixelsHigh(displayID)
            if pxW <= Int(b.width) + 1 && pxH <= Int(b.height) + 1 {
                streamW = pxW * 2
                streamH = pxH * 2
            } else {
                streamW = pxW
                streamH = pxH
            }
            print("[ds] mirror: main display \(streamW)x\(streamH) px")

        case .extend:
            // Create the virtual display (main thread required — we are).
            let created = rates.withUnsafeBufferPointer { ratesBuf in
                vd_create_display(UInt32(settings.panelW), UInt32(settings.panelH),
                                  ratesBuf.baseAddress, ratesBuf.count,
                                  settings.hidpi,
                                  0x041A, 0x371F, 0x2023,
                                  "Xiaoxin Pad Pro 12.7")
            }
            guard created != 0 else {
                print("[ds] FATAL: virtual display creation failed")
                return
            }
            displayID = created
            virtualCreated = true
            streamW = settings.panelW
            streamH = settings.panelH
            print("[ds] extend: virtual display id=\(displayID)")

            applyLogical(settings.logicalW, settings.logicalH, quiet: true)
            arrangement.attach(displayID)
        }

        injector = InputInjector(displayID: displayID)
        pipeline = Pipeline(displayID: displayID)

        // If a client is already connected, restart streaming immediately.
        if server.hasClient {
            startPipelineAndAck()
        }
    }


    /// Selects the ladder mode closest to the requested logical size.
    /// Prefers a synthesized HiDPI @2x variant (points = W, pixels = 2W):
    /// by default CGDisplayCopyAllDisplayModes HIDES those; requesting them
    /// via kCGDisplayShowDuplicateLowResolutionModes is the missing key
    /// (technique from hidpi-mirror / BetterDummy).
    func applyLogical(_ w: Int, _ h: Int, quiet: Bool = false) {
        guard settings.mode == .extend, displayID != 0 else { return }
        Thread.sleep(forTimeInterval: 0.3) // let WindowServer settle after creation
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, opts) as? [CGDisplayMode] else { return }

        // best @2x mode matching the requested points size
        let retina = modes.first {
            $0.width == w && $0.height == h && $0.pixelWidth == w * 2 && $0.pixelHeight == h * 2
        }
        var want = retina
        if want == nil {
            want = modes.min {
                let d1 = abs($0.width - w) + abs($0.height - h)
                let d2 = abs($1.width - w) + abs($1.height - h)
                return d1 == d2 ? $0.refreshRate > $1.refreshRate : d1 < d2
            }
        }
        guard let mode = want else { return }
        let err = CGDisplaySetDisplayMode(displayID, mode, nil)
        if !quiet {
            print("[ds] logical \(mode.width)x\(mode.height) (px \(mode.pixelWidth)x\(mode.pixelHeight))" +
                  "\(retina != nil ? " [RETINA @2x]" : ""): err=\(err.rawValue)")
        }
        settings.logicalW = mode.width
        settings.logicalH = mode.height
    }

    func setMode(_ mode: Mode) {
        guard mode != settings.mode else { return }
        print("[ds] switch mode -> \(mode.rawValue)")
        settings.mode = mode
        applyMode()
    }

    func setLogical(w: Int, h: Int) {
        guard settings.mode == .extend else { return }
        injector?.reset()
        arrangement.detach()
        applyLogical(w, h)
        arrangement.attach(displayID)
        injector?.refreshBounds()
        pipeline?.kickAfterReconnect()
        sendAck()
    }

    func setFps(_ fps: Int) {
        guard fps != settings.fps else { return }
        settings.fps = fps
        pipeline?.reset()
        if server.hasClient { startPipelineAndAck() }
    }

    // MARK: server wiring

    private func wireServer() {
        server.onControl = { [weak self] hello in
            guard let self else { return }
            let session = self.server.currentSession
            // Always enqueue: server callbacks share a serial queue. Async main
            // delivery preserves their order without blocking pipeline work.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.server.currentSession == session else { return }
                // remote commands from the tablet (settings panel)
                if let cmd = hello["cmd"] as? String {
                    self.handleCommand(cmd, hello)
                    return
                }
                guard (hello["magic"] as? String) == "DSXP" else { return }
                do {
                    let codec = try CodecNegotiation.select(hello: hello)
                    self.negotiatedSession = (session, codec)
                } catch {
                    self.negotiatedSession = nil
                    self.pipeline?.reset()
                    self.server.sendControl(["ok": false, "error": "Invalid or unsupported video codecs"], forSession: session)
                    return
                }
                let clientW = hello["width"] as? Int ?? self.settings.panelW
                let clientH = hello["height"] as? Int ?? self.settings.panelH
                let clientHz = hello["maxRefresh"] as? Int ?? 144
                print("[ds] tablet hello: \(clientW)x\(clientH), panel \(clientHz) Hz")
                self.injector?.refreshBounds()
                self.startPipelineAndAck()
            }
        }
        server.onInput = { [weak self] json in
            // Arrival stamped on the server queue (frame-parse time), before
            // the async main-thread dispatch adds latency to "arr".
            self?.inputProbe.note(ts: json["ts"] as? Double,
                                  arrivalNs: Double(DispatchTime.now().uptimeNanoseconds))
            DispatchQueue.main.async { self?.injector?.handle(json) }
        }
        server.onClientStats = { [weak self] stats in
            self?.clockSync.noteArrival(t1: stats["t1"] as? Double,
                                        hostArrivalNs: Double(DispatchTime.now().uptimeNanoseconds))
            DispatchQueue.main.async { self?.adaptBitrate(clientStats: stats) }
        }
        server.onClientConnected = { [weak self] in
            DispatchQueue.main.async {
                self?.negotiatedSession = nil
                // Also covers replacement of an existing single-client session.
                self?.injector?.reset()
                self?.injector?.refreshBounds()
            }
        }
        server.onClientDisconnected = { [weak self] in
            DispatchQueue.main.async {
                self?.negotiatedSession = nil
                self?.injector?.reset()
                print("[ds] client disconnected; display stays, pipeline idles")
            }
        }
    }

    private func handleCommand(_ cmd: String, _ json: [String: Any]) {
        switch cmd {
        case "setMode":
            if let m = (json["mode"] as? String).flatMap(Mode.init(rawValue:)) {
                setMode(m)
            }
        case "setLogical":
            if let w = json["w"] as? Int, let h = json["h"] as? Int {
                setLogical(w: w, h: h)
            }
        case "setFps":
            if let f = json["fps"] as? Int {
                setFps(f)
            }
        default:
            break
        }
    }

    private func startPipelineAndAck() {
        guard let session = negotiatedSession, server.currentSession == session.id else { return }
        guard let pipeline else {
            server.sendControl(["ok": false, "error": "Display pipeline unavailable"], forSession: session.id)
            return
        }
        pipeline.timing.reset() // "seq" is monotonic per connection
        let ready = pipeline.start(server: server, width: streamW, height: streamH,
                                   fps: settings.fps,
                                   bitrateBps: settings.bitrateMbps * 1_000_000,
                                   codec: session.codec, beforeStreaming: { self.sendAck() })
        guard ready else {
            server.sendControl(["ok": false, "error": "Video pipeline startup failed"], forSession: session.id)
            return
        }
        pipeline.kickAfterReconnect()
    }

    private func sendAck() {
        guard let session = negotiatedSession, pipeline?.codec == session.codec else { return }
        server.sendControl([
            "ok": true,
            "width": streamW,
            "height": streamH,
            "fps": settings.fps,
            "bitrate": settings.bitrateMbps * 1_000_000,
            "codec": session.codec.rawValue,
            "mirror": settings.mode == .mirror,
            "logicalW": settings.logicalW,
            "logicalH": settings.logicalH,
            "audio": "pcm16",
            "audioRate": 48000,
            "audioChannels": 2,
            "displayID": Int(displayID),
        ], forSession: session.id)
    }

    private func sendStats() {
        guard server.hasClient else { return }
        let hostNowNs = Double(DispatchTime.now().uptimeNanoseconds)
        var stats: [String: Any] = [
            "hostFps": pipeline?.currentFps ?? 0,
            "mode": settings.mode.rawValue,
            "logical": "\(settings.logicalW)x\(settings.logicalH)",
            "bitrateMbps": settings.bitrateMbps,
            // Client uses this to sanity-check monotonic cap in 0x05 sidecars
            // (FIFO desync mitigation when the encoder drops a frame).
            "hostNow": hostNowNs,
        ]
        if let sync = clockSync.takePayload(nowNs: hostNowNs) {
            stats["sync"] = sync
        }
        if let probe = inputProbe.takePayload() {
            stats["inProbe"] = probe
        }
        server.sendStats(stats)
    }

    // MARK: adaptive bitrate

    /// AIMD-style control driven by end-to-end latency reported by the tablet:
    /// cut hard when the pipe is congested (latency climbs = queues are full),
    /// creep back up when it has been consistently healthy.
    private func adaptBitrate(clientStats: [String: Any]) {
        guard maxBitrateBps == 0 else { return adapt(clientStats: clientStats) }
        maxBitrateBps = settings.bitrateMbps * 1_000_000
        currentBitrateBps = maxBitrateBps
    }

    private func adapt(clientStats: [String: Any]) {
        let now = Date()
        guard now.timeIntervalSince(lastAdjust) >= 3 else { return }
        guard let latency = clientStats["latencyMs"] as? Double else { return }

        var next = currentBitrateBps
        if latency > 60 {
            next = Int(Double(currentBitrateBps) * 0.75)
            goodWindows = 0
        } else if latency > 40 {
            next = Int(Double(currentBitrateBps) * 0.9)
            goodWindows = 0
        } else if latency < 30 {
            goodWindows += 1
            if goodWindows >= 3 {
                next = min(Int(Double(currentBitrateBps) * 1.1), maxBitrateBps)
                goodWindows = 0
            }
        } else {
            goodWindows = 0
        }

        next = max(next, 8_000_000)
        if next != currentBitrateBps {
            currentBitrateBps = next
            lastAdjust = now
            settings.bitrateMbps = next / 1_000_000
            pipeline?.setBitrate(next)
            print(String(format: "[abr] latency %.0f ms -> %d Mbps", latency, next / 1_000_000))
        }
    }

    private func setupSignalHandler() {
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                self?.prepareForTermination()
                self?.shutdown()
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// No exit()/terminate() here: Sparkle and normal NSApplication shutdown
    /// must share cleanup without recursive termination or bypassing its relaunch.
    func prepareForTermination() {
        precondition(Thread.isMainThread)
        terminationPreparation.run {
            print("\n[ds] shutting down…")
            HostLog.shared.write("host shutdown requested")
            audioPresence.stop()
            timers.forEach { $0.invalidate() }; timers.removeAll()
            signalSources.forEach { $0.cancel() }; signalSources.removeAll()
            server.onControl = nil; server.onInput = nil
            server.onClientStats = nil; server.onClientConnected = nil; server.onClientDisconnected = nil
            injector?.reset(); injector = nil
            arrangement.detach()
            pipeline?.reset(); pipeline = nil
            server.stop()
            if virtualCreated { vd_release_display(); virtualCreated = false }
            displayID = 0
            HostLog.shared.flush()
        }
    }

    func shutdown() {
        precondition(Thread.isMainThread)
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - USB autopilot

final class UsbWatchdog {
    private let adbPath: String
    private let server: FrameServer
    private let port: UInt16
    private var lastLaunch = Date.distantPast
    private var busy = false // main-thread only
    private let queue = DispatchQueue(label: "ds.usb-watchdog", qos: .utility)

    init?(server: FrameServer, port: UInt16) {
        let candidates = AppRuntimePolicy.adbCandidates(resourceURL: Bundle.main.url(forResource: "adb", withExtension: nil))
        guard let adb = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            print("[usb] adb not found; automatic USB flow disabled")
            return nil
        }
        adbPath = adb
        self.server = server
        self.port = port
    }

    func run(_ arguments: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: adbPath)
        p.arguments = arguments
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        let ended = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in ended.signal() }
        do { try p.run() } catch { return nil }
        if ended.wait(timeout: .now() + 4) == .timedOut {
            p.terminate()
            if ended.wait(timeout: .now() + 1) == .timedOut { kill(p.processIdentifier, SIGKILL) }
            return nil
        }
        guard p.terminationStatus == 0 else { return nil }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }

    func tick() {
        precondition(Thread.isMainThread)
        guard !busy else { return }
        busy = true
        queue.async { [self] in
            performTick()
            DispatchQueue.main.async { [self] in busy = false }
        }
    }

    private func performTick() {
        guard !server.hasClient else { return }
        guard Date().timeIntervalSince(lastLaunch) > 8 else { return }
        guard let out = run(["devices"]),
              out.contains("\tdevice") else { return } // authorized USB device present
        lastLaunch = Date()

        // App already running? Leave it alone — relaunching yanks it out of
        // the user's hands every tick (can't minimize / can't quit).
        // Its own auto-reconnect handles reconnection.
        let running = run(["shell", "pidof", "com.oleg.dualscreen"])?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        _ = run(["reverse", "tcp:\(port)", "tcp:\(port)"])
        if running != true {
            print("[usb] tablet on USB: wiring adb reverse + launching client")
            _ = run(["shell", "am", "start", "-n", "com.oleg.dualscreen/.MainActivity",
                     "--ez", "autoconnect", "true",
                     "--es", "addr", "127.0.0.1:\(port)"])
        }
    }
}

// MARK: - Menu bar UI

final class MenuBar: NSObject, NSMenuDelegate {
    private let host: HostApp
    private var statusItem: NSStatusItem!
    private var uiTimer: Timer?
    private var statusLine: NSMenuItem!

    init(host: HostApp) {
        self.host = host
        self.statusLine = NSMenuItem(title: "…", action: nil, keyEquivalent: "")
        super.init()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🖥"

        let menu = NSMenu()

        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        let about = NSMenuItem(title: "О программе", action: #selector(showAbout), keyEquivalent: "")
        about.target = self; menu.addItem(about)
        let updates = NSMenuItem(title: "Проверить обновления…", action: nil, keyEquivalent: "")
        updates.isEnabled = false
        host.updater?.attach(to: updates)
        menu.addItem(updates)
        let logs = NSMenuItem(title: "Открыть журнал", action: #selector(openLog), keyEquivalent: "")
        logs.target = self; menu.addItem(logs)
        menu.addItem(.separator())

        let modeMenu = NSMenu(title: "Режим")
        for (label, mode) in [("Расширение (второй экран)", HostApp.Mode.extend),
                              ("Зеркало (повтор экрана retina)", HostApp.Mode.mirror)] {
            let item = NSMenuItem(title: label, action: #selector(modeSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            modeMenu.addItem(item)
        }
        let modeItem = NSMenuItem(title: "Режим", action: nil, keyEquivalent: "")
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        let logicalMenu = NSMenu(title: "Размер (extend)")
        for (w, h, label) in [(1472, 920, "  Retina ⭐"), (1920, 1200, " мелко-резко"), (2944, 1840, " 1:1 очень мелко")] {
            let item = NSMenuItem(title: "\(w)×\(h)\(label)", action: #selector(logicalSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = "\(w)x\(h)"
            logicalMenu.addItem(item)
        }
        let logicalItem = NSMenuItem(title: "Размер (extend)", action: nil, keyEquivalent: "")
        logicalItem.submenu = logicalMenu
        menu.addItem(logicalItem)

        let fpsMenu = NSMenu(title: "Кадры/с")
        for f in [120, 90, 60] {
            let item = NSMenuItem(title: "\(f) fps", action: #selector(fpsSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = f
            fpsMenu.addItem(item)
        }
        let fpsItem = NSMenuItem(title: "Кадры/с", action: nil, keyEquivalent: "")
        fpsItem.submenu = fpsMenu
        menu.addItem(fpsItem)

        let autostart = NSMenuItem(title: "Автостарт при входе", action: #selector(toggleAutostart(_:)), keyEquivalent: "")
        autostart.target = self
        autostart.state = LaunchAgent.isInstalled ? .on : .off
        menu.addItem(autostart)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Выйти", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        menu.autoenablesItems = false // targets are set; keep items clickable
        menu.delegate = self
        statusItem.menu = menu

        uiTimer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
        RunLoop.main.add(uiTimer!, forMode: .common)
        DispatchQueue.main.async { [weak self] in self?.refreshStatus() }
    }

    private func refreshStatus() {
        if host.server.hasClient {
            statusLine.title = String(format: "онлайн • %@ • %.0f fps", host.settings.mode.rawValue, host.pipeline?.currentFps ?? 0)
            statusItem.button?.title = "🖥●"
        } else {
            statusLine.title = "ожидание планшета (автостарт: \(LaunchAgent.isInstalled ? "вкл" : "выкл"))"
            statusItem.button?.title = "🖥"
        }
    }

    @objc private func modeSelected(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let m = HostApp.Mode(rawValue: raw) {
            host.setMode(m)
        }
    }

    @objc private func logicalSelected(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? String {
            let parts = s.split(separator: "x")
            if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) {
                host.setLogical(w: w, h: h)
            }
        }
    }

    @objc private func fpsSelected(_ sender: NSMenuItem) {
        if let f = sender.representedObject as? Int {
            host.setFps(f)
        }
    }

    @objc private func toggleAutostart(_ sender: NSMenuItem) {
        do {
            if LaunchAgent.isInstalled { try LaunchAgent.uninstall() }
            else { try LaunchAgent.install() }
        } catch {
            let alert = NSAlert(); alert.messageText = "Не удалось изменить автостарт"
            alert.informativeText = error.localizedDescription; alert.runModal()
        }
        sender.state = LaunchAgent.isInstalled ? .on : .off
        refreshStatus()
    }

    @objc private func showAbout() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "CLI (без app bundle)"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "DualScreen", .applicationVersion: version, .version: build,
            .credits: NSAttributedString(string: "Планшет как второй экран Mac\nЖурнал: ~/Library/Logs/DualScreen/host.log")
        ])
    }

    @objc private func openLog() {
        HostLog.shared.flush()
        let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DualScreen/host.log")
        NSWorkspace.shared.activateFileViewerSelecting([log])
    }

    @objc private func quit() {
        print("[ds] quit from menu")
        host.shutdown()
    }
}

extension MenuBar {
    func menuNeedsUpdate(_ menu: NSMenu) {
        host.updater?.refreshMenuItem()
        for item in menu.items {
            guard let sub = item.submenu else { continue }
            for subItem in sub.items {
                switch item.title {
                case "Режим":
                    subItem.state = (subItem.representedObject as? String) == host.settings.mode.rawValue ? .on : .off
                case "Размер (extend)":
                    subItem.state = (subItem.representedObject as? String) == "\(host.settings.logicalW)x\(host.settings.logicalH)" ? .on : .off
                case "Кадры/с":
                    subItem.state = (subItem.representedObject as? Int) == host.settings.fps ? .on : .off
                default:
                    break
                }
            }
        }
    }
}

// MARK: - entry point

let application = NSApplication.shared
application.setActivationPolicy(.accessory)

// Device-free modes must branch before HostApp construction: no TCC prompts,
// virtual displays, input injection, TCP listener, USB or login-agent changes.
if args.contains("--app-smoke-test") {
    // Regression: these run before any UI in the real bundle context, where
    // UserDefaults(suiteName:) may return nil for the app's own bundle id.
    // A force-unwrap here was an instant launch crash (SIGTRAP) in v1.0.0.
    BundledPreferences.migrateKnownLegacyPlacement()
    _ = DisplayPlacementStore()
    let lifecycle = AppLifecycle()
    application.delegate = lifecycle
    let updater = lifecycle.initializeUpdater()
    DispatchQueue.main.async {
        let result = updater.smokeResult()
        printJSON(result)
        let valid = result["validBundle"] as? Bool == true && result["updaterInitialized"] as? Bool == true && updater.startupError == nil
        if !valid { exit(2) }
        application.terminate(nil)
    }
    withExtendedLifetime((lifecycle, updater)) { application.run() }
    exit(0)
}

if args.contains("--updater-test") {
    do { try UpdaterTestSession.begin() }
    catch { printJSON(["error": error.localizedDescription]); exit(2) }
}
if args.contains("--updater-test") || UpdaterTestSession.isActive {
    let lifecycle = AppLifecycle()
    application.delegate = lifecycle
    if !lifecycle.runUpdaterTest() { exit(2) }
    exit(0)
}

// Finder / `open` already reuse the running application; this also handles a
// direct invocation of Contents/MacOS/DualScreenHost before any server startup.
if Bundle.main.bundleIdentifier == AppRuntimePolicy.bundleIdentifier,
   let existing = NSRunningApplication.runningApplications(withBundleIdentifier: AppRuntimePolicy.bundleIdentifier)
        .first(where: { $0.processIdentifier != getpid() && !$0.isTerminated }) {
    existing.activate(options: [.activateIgnoringOtherApps])
    exit(0)
}
BundledPreferences.migrateKnownLegacyPlacement()
var autostartMigrationError: Error?
do { try LaunchAgent.migrateLegacyIfNeeded() }
catch {
    autostartMigrationError = error
    FileHandle.standardError.write(Data(("[autostart] " + error.localizedDescription + "\n").utf8))
}

var settings = HostApp.Settings(
    mode: args.contains("--mirror") ? .mirror : .extend,
    // TRUE Retina: 1472x920 points rendered into a 2944x1840 backing store
    // (HiDPI mode selected via kCGDisplayShowDuplicateLowResolutionModes) —
    // MacBook-grade sharpness with comfortable element sizes.
    logicalW: 1472,
    logicalH: 920,
    panelW: Int(argValue("--width", "2944"))!,
    panelH: Int(argValue("--height", "1840"))!,
    fps: Int(argValue("--fps", "120"))!,
    bitrateMbps: Int(argValue("--bitrate", "80"))!,
    port: UInt16(argValue("--port", "7381"))!,
    hidpi: !args.contains("--no-hidpi")
)

let logicalArg = argValue("--logical", "")
if !logicalArg.isEmpty {
    let parts = logicalArg.split(whereSeparator: { $0 == "x" || $0 == "X" })
    if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) {
        settings.logicalW = w
        settings.logicalH = h
    }
}

print("[ds] DualScreenHost starting: mode=\(settings.mode.rawValue) panel=\(settings.panelW)x\(settings.panelH), \(settings.fps)fps, \(settings.bitrateMbps) Mbps, port \(settings.port)")
let hostApp = HostApp(settings: settings)
let lifecycle = AppLifecycle(isStreaming: { hostApp.server.hasClient }, prepare: { hostApp.prepareForTermination() })
application.delegate = lifecycle
if let error = autostartMigrationError {
    let alert = NSAlert(); alert.messageText = "Требуется исправить автостарт"
    alert.informativeText = error.localizedDescription + "\nПроверка обновлений отключена, пока старый самоперезапускающийся LaunchAgent не будет отключён."
    if Bundle.main.bundleURL.pathExtension == "app" { alert.runModal() }
} else {
    hostApp.updater = lifecycle.initializeUpdater()
}
hostApp.run()
