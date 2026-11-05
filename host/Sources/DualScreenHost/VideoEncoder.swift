import Foundation
import CoreVideo
import VTEncoderShim

/// Swift wrapper over the VTEncoderShim C API (hardware HEVC, realtime,
/// Annex-B output with parameter sets inlined on keyframes).
final class VideoEncoder {
    enum EncoderError: Error {
        case sessionCreateFailed
    }

    private var handle: UnsafeMutableRawPointer?
    private var selfPointer: UnsafeMutableRawPointer?
    private let ptsBase = CFAbsoluteTimeGetCurrent()

    /// Annex-B access unit, PTS seconds since start, keyframe flag.
    var onPacket: ((Data, Double, Bool) -> Void)?

    func start(width: Int, height: Int, fps: Int, bitrateBps: Int) throws {
        stop()

        let pointer = Unmanaged.passRetained(self).toOpaque()
        let cb: vtenc_packet_cb = { ctx, data, len, pts, isKey in
            guard let ctx else { return }
            let enc = Unmanaged<VideoEncoder>.fromOpaque(ctx).takeUnretainedValue()
            let packet = Data(bytes: data!, count: len)
            enc.onPacket?(packet, pts, isKey != 0)
        }

        guard let h = vtenc_create(UInt32(width), UInt32(height), UInt32(fps),
                                   UInt32(bitrateBps), cb, pointer) else {
            Unmanaged<VideoEncoder>.fromOpaque(pointer).release()
            throw EncoderError.sessionCreateFailed
        }
        handle = h
        selfPointer = pointer
    }

    func encode(frame: CVImageBuffer, forceKeyframe: Bool = false) {
        guard let handle else { return }
        let pts = CFAbsoluteTimeGetCurrent() - ptsBase
        _ = vtenc_encode(handle, frame, pts, forceKeyframe ? 1 : 0)
    }

    func stop() {
        if let handle { vtenc_destroy(handle) }
        handle = nil
        if let selfPointer {
            Unmanaged<VideoEncoder>.fromOpaque(selfPointer).release()
            self.selfPointer = nil
        }
    }

    deinit { stop() }
}
