import Foundation

/// Connection diagnostics only. Never pass input events, JSON payloads or typed text.
final class HostLog {
    static let shared = HostLog(url: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/DualScreen/host.log"))

    private let url: URL
    private let maxBytes: Int
    private let queue = DispatchQueue(label: "ds.connection-log", qos: .utility)
    private let formatter = ISO8601DateFormatter()
    private var warned = false

    init(url: URL, maxBytes: Int = 512 * 1024) {
        self.url = url
        self.maxBytes = max(128, maxBytes)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func write(_ message: String) {
        let now = Date()
        queue.async { [self] in
            let safe = message.replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
            var line = "\(formatter.string(from: now)) [host pid=\(ProcessInfo.processInfo.processIdentifier)] \(safe)\n"
            if line.utf8.count > maxBytes {
                // Reserve room for a replacement scalar at a split UTF-8 boundary and the newline.
                line = String(decoding: line.utf8.prefix(maxBytes - 4), as: UTF8.self) + "\n"
            }
            let data = Data(line.utf8)
            print(line, terminator: "")
            do {
                let files = FileManager.default
                try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if files.fileExists(atPath: url.path) {
                    let size = (try files.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
                    if size > maxBytes - data.count {
                        let backup = url.appendingPathExtension("1")
                        if files.fileExists(atPath: backup.path) { try files.removeItem(at: backup) }
                        try files.moveItem(at: url, to: backup)
                    }
                }
                if !files.fileExists(atPath: url.path) {
                    guard files.createFile(atPath: url.path, contents: nil) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                _ = try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                if !warned {
                    warned = true
                    FileHandle.standardError.write(Data("[log] cannot persist connection diagnostics: \(error)\n".utf8))
                }
            }
        }
    }

    func flush() {
        queue.sync {}
    }
}
