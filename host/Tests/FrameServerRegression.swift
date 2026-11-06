import Foundation
import Darwin

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { print("FAIL: \(message)"); exit(1) }
}
private func eventually(_ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return condition()
}
private final class Counter {
    private let lock = NSLock()
    private var stored = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return stored }
    func increment() { lock.lock(); stored += 1; lock.unlock() }
}
private func address(_ port: UInt16) -> sockaddr_in {
    var value = sockaddr_in()
    value.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    value.sin_family = sa_family_t(AF_INET)
    value.sin_port = port.bigEndian
    value.sin_addr.s_addr = inet_addr("127.0.0.1")
    return value
}
private func withAddress<T>(_ value: inout sockaddr_in, _ body: (UnsafePointer<sockaddr>) -> T) -> T {
    withUnsafePointer(to: &value) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1, body)
    }
}
private func availablePort() -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    check(fd >= 0, "allocate port probe socket")
    defer { close(fd) }
    var addr = address(0)
    check(withAddress(&addr) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } == 0, "bind port probe")
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let result = withUnsafeMutablePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    check(result == 0, "read probe port")
    return UInt16(bigEndian: addr.sin_port)
}
private func connectClient(_ port: UInt16) -> Int32 {
    let deadline = Date().addingTimeInterval(3)
    repeat {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = address(port)
        if withAddress(&addr, { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }) == 0 {
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            return fd
        }
        close(fd)
        Thread.sleep(forTimeInterval: 0.01)
    } while Date() < deadline
    print("FAIL: connect loopback client"); exit(1)
}
private func receiveExactly(_ fd: Int32, count: Int) -> [UInt8]? {
    var bytes = [UInt8](repeating: 0, count: count)
    var offset = 0
    while offset < count {
        let result = bytes.withUnsafeMutableBytes { buffer in
            recv(fd, buffer.baseAddress!.advanced(by: offset), count - offset, 0)
        }
        guard result > 0 else { return nil }
        offset += result
    }
    return bytes
}
private func receivesControl(_ fd: Int32) -> Bool {
    guard let header = receiveExactly(fd, count: 5), header[0] == 0 else { return false }
    let count = Int(header[1]) << 24 | Int(header[2]) << 16 | Int(header[3]) << 8 | Int(header[4])
    guard count <= 1 << 20, let body = receiveExactly(fd, count: count),
          let value = try? JSONSerialization.jsonObject(with: Data(body)) as? [String: Bool] else { return false }
    return value["probe"] == true
}

@main struct FrameServerRegression {
    static func main() throws {
        let port = availablePort()
        let logURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSHomeDirectory())
            .appendingPathComponent("dualscreen-server-\(UUID().uuidString).log")
        let log = HostLog(url: logURL)
        defer { log.flush(); try? FileManager.default.removeItem(at: logURL) }
        let server = FrameServer(log: log)
        let connected = Counter()
        let disconnected = Counter()
        server.onClientConnected = { connected.increment() }
        server.onClientDisconnected = { disconnected.increment() }
        try server.start(port: port)
        let first = connectClient(port)
        check(eventually { connected.value == 1 && server.hasClient }, "first connection ready")
        _ = shutdown(first, SHUT_RDWR)
        close(first)
        check(eventually { !server.hasClient && disconnected.value == 1 }, "EOF must release the active connection and notify disconnect exactly once")
        print("PASS: peer EOF releases session")

        let second = connectClient(port)
        check(eventually { connected.value == 2 && server.hasClient }, "second connection ready")
        let third = connectClient(port)
        check(eventually { connected.value == 3 && server.hasClient }, "replacement must remain active after the old cancellation callback")
        check(disconnected.value == 2, "replacing a live connection must notify disconnect for releasing held input")
        server.sendControl(["probe": true])
        check(receivesControl(third), "replacement receives server output")
        close(second)
        _ = shutdown(third, SHUT_RDWR)
        close(third)
        check(eventually { !server.hasClient && disconnected.value == 3 }, "replacement EOF emits one disconnect")
        print("PASS: replacing a live session cannot cancel the new connection")

        let malformed = connectClient(port)
        check(eventually { connected.value == 4 && server.hasClient }, "malformed client ready")
        let header: [UInt8] = [0, 0xff, 0xff, 0xff, 0xff]
        check(header.withUnsafeBytes { send(malformed, $0.baseAddress, $0.count, 0) } == 5, "send oversized frame header")
        check(eventually { !server.hasClient && disconnected.value == 4 }, "oversized frame header must close the session without buffering its payload")
        close(malformed)
        print("PASS: oversized incoming frame rejected")

        let baseConnected = connected.value
        let baseDisconnected = disconnected.value
        var previous: Int32?
        for index in 0..<12 {
            let fd = connectClient(port)
            check(eventually { connected.value == baseConnected + index + 1 && server.hasClient }, "rapid replacement \(index) stays connected")
            if let previous { close(previous) }
            server.sendControl(["probe": true])
            check(receivesControl(fd), "rapid replacement \(index) receives output")
            previous = fd
        }
        if let previous { _ = shutdown(previous, SHUT_RDWR); close(previous) }
        check(eventually { !server.hasClient && disconnected.value == baseDisconnected + 12 }, "rapid replacements notify one disconnect each")
        print("PASS: twelve rapid replacements preserve the active connection")
        log.flush()
        let events = try String(contentsOf: logURL, encoding: .utf8)
        check(events.contains("reason=peer EOF") && events.contains("reason=replaced by a new client") && events.contains("durationMs="), "persistent diagnostics record exact disconnect reasons and session duration")
        print("PASS: persistent disconnect reasons")
    }
}
