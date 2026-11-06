import Foundation

@main struct HostLogRegression {
    static func main() throws {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSHomeDirectory()).appendingPathComponent("dualscreen-log-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appendingPathComponent("host.log")
        let log = HostLog(url: url, maxBytes: 256)
        log.write("connected session=first\nforged-line")
        log.flush()
        let text = try String(contentsOf: url, encoding: .utf8)
        guard text.contains("connected session=first forged-line"), text.split(separator: "\n").count == 1, text.contains("T") else {
            fatalError("FAIL: a timestamped event is persisted as one line")
        }
        print("PASS: timestamped persistent event, newline sanitization")

        for index in 0..<10 { log.write("session=\(index) " + String(repeating: "x", count: 120)) }
        log.write("oversized=" + String(repeating: "я", count: 4096))
        log.flush()
        let backup = url.appendingPathExtension("1")
        let live = try Data(contentsOf: url)
        let previous = try Data(contentsOf: backup)
        guard live.count <= 256, previous.count <= 256,
              String(data: live, encoding: .utf8) != nil else {
            fatalError("FAIL: rotated log files and an oversized UTF-8 event must stay bounded")
        }
        print("PASS: bounded rotation and oversized Unicode line")
    }
}
