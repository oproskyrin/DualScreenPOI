import Foundation
import CoreAudio
import AudioUnit

/// Tablet microphone → Mac input path (docs/mic-0x07.md).
///
/// Contract: 0x07 frames carry raw PCM16LE mono 48 kHz on the server
/// connection queue; the route must never block that reader. Frames are
/// dropped silently when mic was not negotiated, when the DualScreenMic HAL
/// is absent, or when the ring is full.
///
/// Feed mechanism mirrors the output HAL (see TabletAudioRoute): PCM enters
/// the BlackHole-derived driver ring through ordinary CoreAudio *playback*
/// into the device — an AudioUnit HAL output bound to UID `DualScreenMic_UID`.
/// The host never touches coreaudiod, its sandbox or driver memory directly;
/// the mic HAL variant bridges its (never-default) output stream into the
/// same ring that capture clients read as microphone data.
protocol MicAudioSink: AnyObject {
    /// Writes mono PCM16 samples; returns the accepted count (overflow is
    /// dropped inside the sink — the render callback drains the HAL ring).
    @discardableResult
    func write(_ samples: ArraySlice<Int16>) -> Int
    var isActive: Bool { get }
}

/// Fixed-capacity PCM16 ring between the 0x07 reader and the render callback.
/// The writer never blocks: when full, the incoming excess is dropped (the
/// documented overfill behavior); the reader side always wins the lock race
/// only briefly — no lock is held across IO or logging.
final class MicRingBuffer {
    private var storage: [Int16]
    private var readIndex = 0
    private var buffered = 0
    private let lock = NSLock()

    /// ~171 ms at 48 kHz — enough to absorb send batching jitter without
    /// adding audible latency to a capture client.
    init(capacity: Int = 8192) {
        storage = [Int16](repeating: 0, count: max(1, capacity))
    }

    var capacity: Int { storage.count }
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return buffered
    }

    /// Writes as much as fits and drops the rest; returns the accepted count.
    @discardableResult
    func write(_ samples: ArraySlice<Int16>) -> Int {
        guard !samples.isEmpty else { return 0 }
        lock.lock(); defer { lock.unlock() }
        let accepted = min(samples.count, storage.count - buffered)
        guard accepted > 0 else { return 0 }
        var writeIndex = (readIndex + buffered) % storage.count
        var offset = samples.startIndex
        var remaining = accepted
        while remaining > 0 {
            let contiguous = min(remaining, storage.count - writeIndex)
            storage.replaceSubrange(writeIndex..<writeIndex + contiguous,
                                    with: samples[offset..<offset + contiguous])
            writeIndex = (writeIndex + contiguous) % storage.count
            offset += contiguous
            remaining -= contiguous
        }
        buffered += accepted
        return accepted
    }

    /// Pops up to `maxCount` samples; the returned array may be shorter than
    /// requested (the consumer zero-fills the rest instead of blocking).
    func drain(_ maxCount: Int) -> [Int16] {
        lock.lock(); defer { lock.unlock() }
        let total = min(max(0, maxCount), buffered)
        var result = [Int16](repeating: 0, count: total)
        var offset = 0
        var remaining = total
        while remaining > 0 {
            let contiguous = min(remaining, storage.count - readIndex)
            result.replaceSubrange(offset..<offset + contiguous,
                                   with: storage[readIndex..<readIndex + contiguous])
            readIndex = (readIndex + contiguous) % storage.count
            offset += contiguous
            remaining -= contiguous
        }
        buffered -= total
        return result
    }
}

/// CoreAudio device lookup for the mic HAL, mirroring TabletAudioRoute's
/// fail-closed UID matching with a short cache. Finds a device whose UID is
/// `DualScreenMic_UID` and that exposes an output stream (the feed path).
enum MicDeviceLookup {
    static let deviceUID = "DualScreenMic_UID"

    static func find() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioDeviceID>.size else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return nil }
        for id in ids {
            var alive: UInt32 = 0
            var aliveAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsAlive,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var aliveSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(id, &aliveAddress, 0, nil, &aliveSize, &alive) == noErr, alive != 0 else { continue }
            var uid: Unmanaged<CFString>?
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &uidAddress, 0, nil, &uidSize, &uid) == noErr,
                  let uid, uid.takeUnretainedValue() as String == deviceUID else { continue }
            var streamsAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain)
            var streamBytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streamsAddress, 0, nil, &streamBytes) == noErr,
                  streamBytes > 0 else { continue }
            return id
        }
        return nil
    }
}

/// Plays negotiated tablet PCM into the DualScreenMic device through the
/// public AudioUnit HAL output — the same path system audio uses to reach the
/// DualScreenAudio output HAL. The driver bridges played frames into its ring
/// buffer; coreaudiod serves them to capture clients as microphone input.
/// Zero-fill in the render callback is the drain-side silence: the callback
/// never blocks or waits for the writer.
final class MicHALWriter: MicAudioSink {
    private let ring: MicRingBuffer
    private let deviceID: AudioDeviceID
    private var unit: AudioUnit?
    private(set) var isActive = false

    init?(deviceID: AudioDeviceID, ringCapacity: Int = 8192) {
        self.deviceID = deviceID
        self.ring = MicRingBuffer(capacity: ringCapacity)
        guard startUnit() else {
            stop()
            return nil
        }
    }

    var bufferedCount: Int { ring.count }

    func write(_ samples: ArraySlice<Int16>) -> Int {
        ring.write(samples)
    }

    func stop() {
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        unit = nil
        isActive = false
    }

    deinit { stop() }

    private func startUnit() -> Bool {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { return false }
        var created: AudioUnit?
        guard AudioComponentInstanceNew(component, &created) == noErr, let unit = created else { return false }
        self.unit = unit
        var device = deviceID
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                   &device, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else { return false }
        // Client format for the HAL output: mono Float32 at the device's only
        // supported rate. AUHAL converts; the device stream itself stays
        // PCM16-visible via the driver's own format handling.
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        guard AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                                   &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)) == noErr else { return false }
        var callback = AURenderCallbackStruct(
            inputProc: MicHALWriter.renderCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        guard AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                   &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr else { return false }
        guard AudioUnitInitialize(unit) == noErr else { return false }
        guard AudioOutputUnitStart(unit) == noErr else { return false }
        isActive = true
        return true
    }

    private static let renderCallback: AURenderCallback = { refCon, _, _, _, frameCount, ioData in
        guard let ioData else { return noErr }
        let writer = Unmanaged<MicHALWriter>.fromOpaque(refCon).takeUnretainedValue()
        let frames = Int(frameCount)
        guard frames > 0 else { return noErr }
        let buffer = ioData.pointee.mBuffers
        guard let data = buffer.mData else { return noErr }
        let capacity = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.size
        let samples = writer.ring.drain(min(frames, capacity))
        let destination = data.assumingMemoryBound(to: Float32.self)
        for index in 0..<min(frames, capacity) {
            destination[index] = index < samples.count
                ? Float32(samples[index]) / 32768.0
                : 0 // underflow is silence, never a stall
        }
        return noErr
    }
}

/// Gates 0x07 PCM into the mic HAL sink. Created once per host process;
/// `setNegotiated` follows the client hello's "mic": true flag exactly like
/// the clipboard capability (cleared on every new session and teardown).
final class MicInputRoute {
    static let presenceNotificationName = "com.oleg.dualscreen.host.mic-pid"

    private let log: HostLog
    private let stateLock = NSLock()
    private var negotiated = false
    private var sink: MicAudioSink?
    private var poller: DispatchSourceTimer?
    private let pollQueue = DispatchQueue(label: "ds.mic-input")
    private let deviceProbe: () -> AudioDeviceID?
    private let sinkFactory: (AudioDeviceID) -> MicAudioSink?
    private var lastProbe = Date.distantPast
    private var cachedDevice: AudioDeviceID?

    // Drop diagnostics: sizes/counts only, never PCM bytes (HostLog contract).
    private var dropsNotNegotiated = 0
    private var dropsNoDevice = 0
    private var dropsRingFull = 0
    private var receivedBytes = 0
    private var lastReport = Date.distantPast
    private var reportedNotNegotiated = 0
    private var reportedNoDevice = 0
    private var reportedRingFull = 0

    init(log: HostLog = .shared,
         deviceProbe: @escaping () -> AudioDeviceID? = MicDeviceLookup.find,
         sinkFactory: @escaping (AudioDeviceID) -> MicAudioSink? = { MicHALWriter(deviceID: $0) }) {
        self.log = log
        self.deviceProbe = deviceProbe
        self.sinkFactory = sinkFactory
    }

    var isNegotiated: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return negotiated
    }

    /// Present when the probe found the HAL and its sink is running.
    var hasActiveSink: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return sink?.isActive == true
    }

    var dropCounters: (notNegotiated: Int, noDevice: Int, ringFull: Int) {
        stateLock.lock(); defer { stateLock.unlock() }
        return (dropsNotNegotiated, dropsNoDevice, dropsRingFull)
    }

    /// Begins polling for the mic HAL. Safe to call before the device exists;
    /// the sink appears/disappears with the device (heartbeat presence).
    func start() {
        pollQueue.async { [weak self] in
            guard let self, self.poller == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: self.pollQueue)
            source.schedule(deadline: .now(), repeating: .milliseconds(500), leeway: .milliseconds(100))
            source.setEventHandler { [weak self] in self?.poll() }
            self.poller = source
            source.resume()
        }
    }

    func stop() {
        pollQueue.async { [weak self] in
            guard let self else { return }
            self.poller?.cancel()
            self.poller = nil
            self.stopSink()
        }
    }

    func setNegotiated(_ flag: Bool) {
        stateLock.lock(); defer { stateLock.unlock() }
        if negotiated != flag {
            log.write("mic route negotiated=\(flag)")
        }
        negotiated = flag
    }

    /// Called on the server connection queue for every 0x07 frame. Never
    /// blocks, never throws; all failures are silent drops (see contract).
    func accept(_ pcm: Data) {
        let byteCount = pcm.count
        let samples = pcm.micMonoSamples()
        stateLock.lock()
        if !negotiated {
            dropsNotNegotiated += 1
        } else if sink == nil {
            dropsNoDevice += 1
        }
        let currentSink = sink
        let allowed = negotiated && currentSink != nil
        stateLock.unlock()
        guard allowed, let currentSink else { reportDrops(force: false); return }
        guard !samples.isEmpty else { return }
        let accepted = currentSink.write(samples[...])
        stateLock.lock()
        receivedBytes += byteCount
        dropsRingFull += samples.count - accepted
        stateLock.unlock()
        reportDrops(force: false)
    }

    // MARK: - sink lifecycle (poll queue only)

    private func poll() {
        let now = Date()
        var device: AudioDeviceID?
        if now.timeIntervalSince(lastProbe) >= 0.1 {
            lastProbe = now
            device = deviceProbe()
            stateLock.lock()
            cachedDevice = device
            stateLock.unlock()
        } else {
            stateLock.lock()
            device = cachedDevice
            stateLock.unlock()
        }
        guard let device else {
            stopSink()
            return
        }
        if hasActiveSink { return }
        guard let newSink = sinkFactory(device), newSink.isActive else { return }
        setSink(newSink)
    }

    private func setSink(_ newSink: MicAudioSink?) {
        stateLock.lock()
        let old = sink
        sink = newSink
        stateLock.unlock()
        if newSink !== old {
            (old as? MicHALWriter)?.stop()
            if newSink != nil {
                log.write("mic HAL sink active uid=\(MicDeviceLookup.deviceUID)")
            } else if old != nil {
                log.write("mic HAL sink removed")
            }
        }
    }

    private func stopSink() {
        setSink(nil)
    }

    private func reportDrops(force: Bool) {
        stateLock.lock()
        let now = Date()
        let pending = (dropsNotNegotiated - reportedNotNegotiated)
            + (dropsNoDevice - reportedNoDevice)
            + (dropsRingFull - reportedRingFull)
        guard pending > 0, force || now.timeIntervalSince(lastReport) >= 3 else {
            stateLock.unlock()
            return
        }
        let line = "mic drops notNegotiated=\(dropsNotNegotiated) noDevice=\(dropsNoDevice) ringFull=\(dropsRingFull) receivedBytes=\(receivedBytes)"
        reportedNotNegotiated = dropsNotNegotiated
        reportedNoDevice = dropsNoDevice
        reportedRingFull = dropsRingFull
        lastReport = now
        stateLock.unlock()
        log.write(line)
    }
}

extension Data {
    /// Raw PCM16LE mono payload → samples; a trailing odd byte is ignored.
    func micMonoSamples() -> [Int16] {
        let pairs = count / 2
        guard pairs > 0 else { return [] }
        return withUnsafeBytes { raw in
            (0..<pairs).map {
                Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))
            }
        }
    }
}
