import Foundation
import Darwin

@main struct ServerLifecycleTests {
    static func main() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        assert(bound == 0 && listen(fd, 1) == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        let logURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"]!).appendingPathComponent("server-lifecycle-\(UUID().uuidString).log")
        let log = HostLog(url: logURL)
        defer { log.flush(); try? FileManager.default.removeItem(at: logURL) }
        let server = FrameServer(log: log)
        var rejected = false
        do { try server.start(port: UInt16(bigEndian: address.sin_port)) }
        catch { rejected = true }
        assert(rejected, "port collision must throw, not merely log an asynchronous failure")
        server.stop()
        server.stop()
        assert(!server.hasClient)
        print("PASS startup rejects occupied port; repeated stop is safe")
    }
}
