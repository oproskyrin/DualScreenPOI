import Foundation
import AppKit
import CoreGraphics
import CGVirtualDisplayShim

// DualScreenHost — turns an Android tablet into a second display for macOS.
//
// Pipeline: CGVirtualDisplay (private API, extend) or the main display
// (mirror) -> ScreenCaptureKit -> VideoToolbox HEVC (hardware, realtime) ->
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
    private var started = false
    private var encoderReady = false
    private let lock = NSLock()
    private var fpsWindowStart = Date()
    private var fpsCount = 0
    private var dbgPackets = 0
    private var dbgKeysDumped = 0
    private var forceKeyFrames = 0
    private var lastRestart = Date.distantPast
    private(set) var currentFps: Double = 0

    /// Walks Annex-B NALs and prints their HEVC types (32=VPS, 33=SPS, 34=PPS).
    func dumpNalTypes(_ data: Data) {
        var types: [Int] = []
        var i = data.startIndex
        while i < data.endIndex - 4 {
            if data[i] == 0, data[i + 1] == 0, data[i + 2] == 0, data[i + 3] == 1 {
                if i + 4 < data.endIndex { types.append(Int((data[i + 4] & 0x7E) >> 1)) }
                i += 4
            } else if data[i] == 0, data[i + 1] == 0, data[i + 2] == 1 {
                if i + 3 < data.endIndex { types.append(Int((data[i + 3] & 0x7E) >> 1)) }
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
            try? await capt.start(fps: f, pixelWidth: w, pixelHeight: h)
        }
    }

    private var captureW = 0, captureH = 0, captureFps = 0

    func start(server: FrameServer, width: Int, height: Int, fps: Int, bitrateBps: Int) {
        lock.lock(); defer { lock.unlock() }
        guard !started else { return }
        started = true
        wire(server: server)

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

    /// Full stop so a new start() can reconfigure (mode/fps/bitrate switch).
    func reset() {
        lock.lock(); defer { lock.unlock() }
        guard started else { return }
        started = false
        encoderReady = false
        let capt = capturer
        capturer.onAudio = nil
        encoder.onPacket = nil
        encoder.stop()
        Task.detached { capt.stop() }
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
    private var menuBar: MenuBar?
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
        // Screen Recording permission (TCC). Prompts on first run.
        if !CGPreflightScreenCaptureAccess() {
            print("[ds] requesting Screen Recording permission…")
            _ = CGRequestScreenCaptureAccess()
        }

        wireServer()
        do {
            try server.start(port: settings.port)
        } catch {
            FileHandle.standardError.write("FATAL: cannot listen on port \(settings.port): \(error)\n".data(using: .utf8)!)
            exit(1)
        }

        applyMode()

        // periodic stats to the tablet
        let statsTimer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.sendStats()
        }
        RunLoop.main.add(statsTimer, forMode: .common)

        // USB autopilot: plug the cable -> everything connects by itself
        if let usb = UsbWatchdog(server: server, port: settings.port) {
            let usbTimer = Timer(timeInterval: 2, repeats: true) { _ in usb.tick() }
            RunLoop.main.add(usbTimer, forMode: .common)
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

            positionRightOfMain()
            applyLogical(settings.logicalW, settings.logicalH, quiet: true)
        }

        injector = InputInjector(displayID: displayID)
        pipeline = Pipeline(displayID: displayID)

        // If a client is already connected, restart streaming immediately.
        if server.hasClient {
            startPipelineAndAck()
        }
    }

    private func positionRightOfMain() {
        var config: CGDisplayConfigRef?
        if CGBeginDisplayConfiguration(&config) == CGError.success {
            let mainBounds = CGDisplayBounds(CGMainDisplayID())
            CGConfigureDisplayOrigin(config, displayID, Int32(mainBounds.maxX), Int32(mainBounds.minY))
            _ = CGCompleteDisplayConfiguration(config, .permanently)
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
        sendAck()
    }

    func setLogical(w: Int, h: Int) {
        guard settings.mode == .extend else { return }
        applyLogical(w, h)
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
            // remote commands from the tablet (settings panel)
            if let cmd = hello["cmd"] as? String {
                self.handleCommand(cmd, hello)
                return
            }
            guard (hello["magic"] as? String) == "DSXP" else { return }
            let clientW = hello["width"] as? Int ?? self.settings.panelW
            let clientH = hello["height"] as? Int ?? self.settings.panelH
            let clientHz = hello["maxRefresh"] as? Int ?? 144
            print("[ds] tablet hello: \(clientW)x\(clientH), panel \(clientHz) Hz")
            self.injector?.refreshBounds()
            self.startPipelineAndAck()
        }
        server.onInput = { [weak self] json in
            self?.injector?.handle(json)
        }
        server.onClientStats = { [weak self] stats in
            self?.adaptBitrate(clientStats: stats)
        }
        server.onClientConnected = { [weak self] in
            self?.injector?.refreshBounds()
        }
        server.onClientDisconnected = {
            print("[ds] client disconnected; display stays, pipeline idles")
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
        guard let pipeline else { return }
        pipeline.start(server: server, width: streamW, height: streamH,
                       fps: settings.fps,
                       bitrateBps: settings.bitrateMbps * 1_000_000)
        pipeline.kickAfterReconnect()
        sendAck()
    }

    private func sendAck() {
        server.sendControl([
            "ok": true,
            "width": streamW,
            "height": streamH,
            "fps": settings.fps,
            "bitrate": settings.bitrateMbps * 1_000_000,
            "codec": "hevc",
            "mirror": settings.mode == .mirror,
            "logicalW": settings.logicalW,
            "logicalH": settings.logicalH,
            "audio": "pcm16",
            "audioRate": 48000,
            "audioChannels": 2,
            "displayID": Int(displayID),
        ])
    }

    private func sendStats() {
        guard server.hasClient else { return }
        server.sendStats([
            "hostFps": pipeline?.currentFps ?? 0,
            "mode": settings.mode.rawValue,
            "logical": "\(settings.logicalW)x\(settings.logicalH)",
            "bitrateMbps": settings.bitrateMbps,
        ])
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
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signal(SIGINT, SIG_IGN)
        source.setEventHandler { [weak self] in
            print("\n[ds] shutting down…")
            self?.pipeline?.reset()
            if self?.virtualCreated == true { vd_release_display() }
            exit(0)
        }
        source.resume()
    }
}

// MARK: - USB autopilot

final class UsbWatchdog {
    private let adbPath: String
    private let server: FrameServer
    private let port: UInt16
    private var lastLaunch = Date.distantPast

    init?(server: FrameServer, port: UInt16) {
        let candidates = ["/opt/homebrew/bin/adb", "/usr/local/bin/adb", "/usr/bin/adb"]
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
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
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
        if LaunchAgent.isInstalled {
            LaunchAgent.uninstall()
        } else {
            LaunchAgent.install()
        }
        sender.state = LaunchAgent.isInstalled ? .on : .off
        refreshStatus()
    }

    @objc private func quit() {
        print("[ds] quit from menu")
        exit(0)
    }
}

extension MenuBar {
    func menuNeedsUpdate(_ menu: NSMenu) {
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

// MARK: - LaunchAgent

enum LaunchAgent {
    static var plistPath: String {
        "\(NSHomeDirectory())/Library/LaunchAgents/com.oleg.dualscreen.host.plist"
    }
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistPath)
    }

    private static var binaryPath: String {
        var path = CommandLine.arguments[0]
        if !path.hasPrefix("/") {
            path = FileManager.default.currentDirectoryPath + "/" + path
        }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    static func install() {
        let plist = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <plist version="1.0">
        <dict>
            <key>Label</key><string>com.oleg.dualscreen.host</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(binaryPath)</string>
            </array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><true/>
        </dict>
        </plist>
        """
        try? plist.write(toFile: plistPath, atomically: true, encoding: .utf8)
        run("/bin/launchctl", ["unload", plistPath])
        run("/bin/launchctl", ["load", plistPath])
        print("[ds] LaunchAgent installed: \(plistPath)")
    }

    static func uninstall() {
        run("/bin/launchctl", ["unload", plistPath])
        try? FileManager.default.removeItem(atPath: plistPath)
        print("[ds] LaunchAgent removed")
    }

    @discardableResult
    private static func run(_ path: String, _ arguments: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = arguments
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit(); return true } catch { return false }
    }
}

// MARK: - entry point

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
hostApp.run()
