import Darwin
import Foundation
import Testing

@testable import OsmoticCore

/// A tiny HTTP/1.1 server on loopback that serves one byte blob and misbehaves the way the camera's
/// lighttpd does on long reads: it cuts transfers mid-stream, answers transient 404/500, and can
/// ignore `Range`.
final class FakeHTTPServer: @unchecked Sendable {
    enum Behavior {
        case serve
        case cutAfter(Int)
        case status(Int)
        case ignoreRange, html, redirect
    }

    let port: UInt16
    private let body: [UInt8]
    private let script: [Behavior]
    private let lock = NSLock()
    private var requests = 0
    private(set) var ranges: [Int] = []
    private var fd: Int32

    init(body: [UInt8], script: [Behavior]) throws {
        self.body = body
        self.script = script
        let s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        listen(s, 8)
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) }
        }
        port = UInt16(bigEndian: bound.sin_port)
        fd = s
        Thread { self.acceptLoop() }.start()
    }

    func stop() { close(fd) }

    var requestCount: Int { lock.withLock { requests } }

    private func acceptLoop() {
        while true {
            let c = accept(fd, nil, nil)
            if c < 0 { return }
            Thread { self.handle(c) }.start()
        }
    }

    private func handle(_ c: Int32) {
        defer { close(c) }
        var one: Int32 = 1
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = buf.withUnsafeMutableBytes { recv(c, $0.baseAddress, $0.count, 0) }
        guard n > 0 else { return }
        let req = String(decoding: buf[0..<n], as: UTF8.self)
        var start = 0
        if let m = req.firstMatch(of: /Range: bytes=(\d+)-/) { start = Int(m.1) ?? 0 }
        let behavior: Behavior = lock.withLock {
            let b = requests < script.count ? script[requests] : .serve
            requests += 1
            ranges.append(start)
            return b
        }
        let isHead = req.hasPrefix("HEAD")
        if start >= body.count, start > 0 {
            write(
                c,
                "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(body.count)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            )
            return
        }
        switch behavior {
        case .html:
            let page = Array("<html>router login</html>".utf8)
            write(c, "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(page.count)\r\nConnection: close\r\n\r\n")
            if !isHead { send(c, page) }
        case .redirect:
            write(
                c,
                "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:9/elsewhere\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        case .status(let code):
            write(c, "HTTP/1.1 \(code) Busy\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        case .ignoreRange:
            write(c, "HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n")
            if !isHead { send(c, body) }
        case .serve, .cutAfter:
            let slice = Array(body[start...])
            let head =
                start > 0
                ? "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes \(start)-\(body.count - 1)/\(body.count)\r\n"
                : "HTTP/1.1 200 OK\r\n"
            write(c, head + "Content-Length: \(slice.count)\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n")
            guard !isHead else { return }
            if case .cutAfter(let k) = behavior { send(c, Array(slice.prefix(k))); return }
            send(c, slice)
        }
    }

    private func write(_ c: Int32, _ s: String) { send(c, Array(s.utf8)) }

    private func send(_ c: Int32, _ bytes: [UInt8]) {
        var off = 0
        while off < bytes.count {
            let w = bytes[off...].withUnsafeBytes { Darwin.send(c, $0.baseAddress, $0.count, 0) }
            if w <= 0 { return }
            off += w
        }
    }
}

@Suite(.serialized) struct DownloaderTests {
    let body: [UInt8] = (0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }

    func run(_ script: [FakeHTTPServer.Behavior], expected: Int? = nil) async throws -> (
        FileDownloader.Result, [UInt8], FakeHTTPServer
    ) {
        let server = try FakeHTTPServer(body: body, script: script)
        let http = CameraHTTP(ip: "127.0.0.1", port: Int(server.port))
        let dl = FileDownloader(http: http, log: { _ in })
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("osmotic-dl-\(UUID().uuidString)")
        let dest = dir.appendingPathComponent("DJI_20260101120000_0001_D.MP4")
        let result = await dl.download(
            urlPath: "/v2?storage=0&path=DCIM/DJI_001/x.MP4", to: dest,
            expectedSize: expected ?? body.count
        ) { _ in }
        let got = (try? Data(contentsOf: dest)).map { [UInt8]($0) } ?? []
        server.stop()
        try? FileManager.default.removeItem(at: dir)
        return (result, got, server)
    }

    @Test(.timeLimit(.minutes(1))) func `a clean transfer lands whole`() async throws {
        let (r, got, _) = try await run([.serve])
        guard case .saved = r else { Issue.record("\(r)"); return }
        #expect(got == body)
    }

    @Test(.timeLimit(.minutes(1))) func `a cut transfer resumes with Range and matches byte for byte`() async throws {
        let (r, got, server) = try await run([.cutAfter(700_000), .cutAfter(900_000), .serve])
        guard case .saved = r else { Issue.record("\(r)"); return }
        #expect(got == body)
        // Where a cut lands depends on socket timing (a cut can even arrive before any byte, so a resume
        // may repeat the same offset); what matters is that no resume ever goes back.
        #expect(server.ranges.count == 3 && server.ranges.first == 0)
        #expect(server.ranges == server.ranges.sorted())
    }

    @Test(.timeLimit(.minutes(1))) func `transient 404 and 500 are waited out, not fatal`() async throws {
        let (r, got, _) = try await run([.status(500), .status(404), .serve])
        guard case .saved = r else { Issue.record("\(r)"); return }
        #expect(got == body)
    }

    @Test(.timeLimit(.minutes(1))) func `an ignored Range restarts from zero instead of corrupting the file`() async throws {
        let (r, got, _) = try await run([.cutAfter(500_000), .ignoreRange, .serve])
        guard case .saved = r else { Issue.record("\(r)"); return }
        #expect(got == body)
    }

    @Test(.timeLimit(.minutes(1))) func `a camera that keeps refusing pauses the file and keeps the part`() async throws {
        let (r, _, server) = try await run(Array(repeating: .status(404), count: 10))
        #expect(r == .paused(bytes: 0))
        #expect(server.requestCount == 5)
    }

    @Test(.timeLimit(.minutes(1))) func `a manifest size smaller than the real file never truncates it`() async throws {
        let (r, got, _) = try await run([.cutAfter(1_500_000), .serve], expected: 1_000_000)
        guard case .saved = r else { Issue.record("\(r)"); return }
        #expect(got == body)
    }

    @Test(.timeLimit(.minutes(1))) func `an HTML page from another device is never saved as the file`() async throws {
        let (r, got, _) = try await run(Array(repeating: .html, count: 10))
        #expect(r == .paused(bytes: 0))
        #expect(got.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func `redirects are not followed`() async throws {
        let (r, got, server) = try await run(Array(repeating: .redirect, count: 10))
        #expect(r == .paused(bytes: 0))
        #expect(got.isEmpty)
        #expect(server.requestCount == 5)
    }

    @Test(.timeLimit(.minutes(1))) func `a part that already holds every byte finishes on 416`() async throws {
        let server = try FakeHTTPServer(body: body, script: [])
        let dl = FileDownloader(http: CameraHTTP(ip: "127.0.0.1", port: Int(server.port)), log: { _ in })
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("osmotic-dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("b.MP4")
        try Data(body).write(to: dest.appendingPathExtension("part"))
        let r = await dl.download(urlPath: "/x", to: dest, expectedSize: 0) { _ in }
        #expect(r == .saved(dest))
        #expect((try? Data(contentsOf: dest)).map { [UInt8]($0) } == body)
        server.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    @Test(.timeLimit(.minutes(1))) func `an existing file is skipped`() async throws {
        let server = try FakeHTTPServer(body: body, script: [])
        let dl = FileDownloader(http: CameraHTTP(ip: "127.0.0.1", port: Int(server.port)), log: { _ in })
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("osmotic-dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("a.MP4")
        try Data([1, 2, 3]).write(to: dest)
        let r = await dl.download(urlPath: "/x", to: dest, expectedSize: 3) { _ in }
        #expect(r == .skipped(dest))
        #expect(server.requestCount == 0)
        server.stop()
    }
}
