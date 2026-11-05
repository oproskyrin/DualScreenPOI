import Foundation
import ScreenCaptureKit
import CoreVideo
import CoreMedia

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

    var onFrame: ((CVImageBuffer, CMTime) -> Void)?
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
        config.showsCursor = false
        config.width = pixelWidth
        config.height = pixelHeight
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.capturesAudio = false

        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "ds.capture", qos: .userInteractive))
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
        guard type == .screen,
              sampleBuffer.isValid,
              let imageBuffer = sampleBuffer.imageBuffer else { return }
        onFrame?(imageBuffer, sampleBuffer.presentationTimeStamp)
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        if self.stream != nil {
            onError?(error)
        }
    }
}
