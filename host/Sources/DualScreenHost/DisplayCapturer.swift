import Foundation
import ScreenCaptureKit
import CoreVideo
import CoreMedia
import VTEncoderShim

/// Captures a specific CGDirectDisplayID with ScreenCaptureKit at a fixed
/// frame rate, delivering NV12 CVImageBuffers.
final class DisplayCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    enum CaptureError: Error {
        case displayNotFound
        case notAuthorized
    }

    private let displayID: CGDirectDisplayID
    private var stream: SCStream?
    private var serial = 0
    private static var loggedFirstFrame = false

    var onFrame: ((CVImageBuffer, CMTime) -> Void)?
    /// Raw 16-bit LE 48kHz stereo PCM chunks of system audio.
    var onAudio: ((Data) -> Void)?
    var onError: ((Error) -> Void)?

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
    }

    /// Waits until the freshly created virtual display registers with
    /// WindowServer (SCShareableContent lags behind CG by a moment).
    static func waitForDisplay(_ id: CGDirectDisplayID, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
               content.displays.contains(where: { $0.displayID == id }) {
                return true
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return false
    }

    func start(fps: Int, pixelWidth: Int, pixelHeight: Int) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 8
        config.showsCursor = true // cursor must be visible on the tablet
        config.width = pixelWidth
        config.height = pixelHeight
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = false

        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "ds.capture", qos: .userInteractive))
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "ds.audio", qos: .userInteractive))
        try await newStream.startCapture()
        stream = newStream
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        serial += 1
        Task { try? await stream.stopCapture() }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            guard let imageBuffer = sampleBuffer.imageBuffer else { return }
            if !Self.loggedFirstFrame {
                Self.loggedFirstFrame = true
                print("[capture] first frame: \(CVPixelBufferGetWidth(imageBuffer))x\(CVPixelBufferGetHeight(imageBuffer)) px")
            }
            onFrame?(imageBuffer, sampleBuffer.presentationTimeStamp)
        case .audio:
            var samples = [Int16](repeating: 0, count: 8192)
            let written = samples.withUnsafeMutableBufferPointer { buf in
                vtaudio_pcm16_stereo(sampleBuffer, buf.baseAddress, buf.count)
            }
            guard written > 0 else { return }
            samples.withUnsafeBytes { raw in
                onAudio?(Data(raw.bindMemory(to: UInt8.self).prefix(written * 2)))
            }
        @unknown default:
            break
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        if self.stream != nil {
            onError?(error)
        }
    }
}
