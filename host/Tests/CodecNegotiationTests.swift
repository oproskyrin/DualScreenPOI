import Foundation

@main struct CodecNegotiationTests {
    static func main() throws {
        let codec = try CodecNegotiation.select(hello: ["codecs": ["hevc", "h264"], "preferredCodec": "h264"])
        precondition(codec == .h264, "supported preference must select AVC")
        let legacy = try CodecNegotiation.select(hello: [:])
        precondition(legacy == .hevc)
        let cases: [([String: Any], VideoCodec)] = [
            (["preferredCodec": "h264"], .hevc),
            (["codecs": ["h264", "hevc"]], .hevc),
            (["codecs": ["h264"]], .h264),
            (["codecs": ["hevc"], "preferredCodec": "h264"], .hevc),
            (["codecs": ["h264"], "preferredCodec": "hevc"], .h264),
            (["codecs": ["hevc", "h264"], "preferredCodec": "avc"], .hevc),
        ]
        for (hello, expected) in cases {
            let selected = try CodecNegotiation.select(hello: hello)
            precondition(selected == expected)
        }
        for invalid: Any in [[], ["av1"], ["H264"], "hevc", NSNull(), [1]] {
            do {
                _ = try CodecNegotiation.select(hello: ["codecs": invalid])
                fatalError("invalid/no common capabilities accepted: \(invalid)")
            } catch {}
        }
        print("PASS supported H264 preference")
    }
}
