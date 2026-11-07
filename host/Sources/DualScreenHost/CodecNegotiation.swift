import Foundation

enum VideoCodec: String { case hevc, h264 }

enum CodecNegotiation {
    enum Failure: Error { case invalidCapabilities, noCommonCodec }

    static func select(hello: [String: Any]) throws -> VideoCodec {
        guard let raw = hello["codecs"] else { return .hevc }
        guard let names = raw as? [String] else { throw Failure.invalidCapabilities }
        if let preferred = hello["preferredCodec"] as? String,
           let codec = VideoCodec(rawValue: preferred), names.contains(preferred) { return codec }
        if names.contains("hevc") { return .hevc }
        if names.contains("h264") { return .h264 }
        throw Failure.noCommonCodec
    }
}
