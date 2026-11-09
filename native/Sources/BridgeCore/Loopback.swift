import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// One-shot loopback HTTP listener for the OAuth redirect (RFC 8252 style). Binds 127.0.0.1 only,
/// accepts connections until one hits `path`, answers with a short page and closes.
public final class LoopbackCallback {
    public let port: Int
    private let fd: Int32
    public let path: String

    public init(path: String = OAuthPairing.callbackPath) throws {
        self.path = path
        #if canImport(Glibc)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        self.fd = fd
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard ok == 0, listen(fd, 4) == 0 else { close(fd); throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var bound = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        self.port = Int(UInt16(bigEndian: bound.sin_port))
    }

    deinit { close(fd) }

    /// Blocks until the browser is redirected to the callback or `timeout` seconds pass.
    public func wait(timeout: Double, page: String = "T3 for WoW: you can close this tab.") -> [String: String]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let r = poll(&pfd, 1, Int32(max(1, min(1000, deadline.timeIntervalSinceNow * 1000))))
            if r <= 0 { continue }
            let c = accept(fd, nil, nil)
            if c < 0 { continue }
            var buf = [UInt8](repeating: 0, count: 8192)
            let n = read(c, &buf, buf.count)
            let req = n > 0 ? String(decoding: buf[0..<n], as: UTF8.self) : ""
            let target = req.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let comps = URLComponents(string: "http://127.0.0.1\(target)")
            let isCallback = comps?.path == path
            let body = isCallback ? "<!doctype html><meta charset=utf-8><title>T3 for WoW</title><p>\(page)</p>" : "Not found"
            let resp = "HTTP/1.1 \(isCallback ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            _ = resp.withCString { write(c, $0, strlen($0)) }
            close(c)
            if isCallback {
                var q: [String: String] = [:]
                for item in comps?.queryItems ?? [] { q[item.name] = item.value ?? "" }
                return q
            }
        }
        return nil
    }
}
