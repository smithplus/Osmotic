import Foundation
import Testing
@testable import OsmoticCore

@Suite struct ThroughputProbe {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OSMOTIC_PERF"] == "1"))
    func `writes keep up with a fast link`() async throws {
        let body = [UInt8](repeating: 0xAB, count: 400_000_000)
        let server = try FakeHTTPServer(body: body, script: [])
        let dl = FileDownloader(http: CameraHTTP(ip: "127.0.0.1", port: Int(server.port)), log: { _ in })
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("perf-\(UUID().uuidString).MP4")
        let t0 = Date()
        let r = await dl.download(urlPath: "/x", to: dest, expectedSize: body.count) { _ in }
        let secs = Date().timeIntervalSince(t0)
        print("THROUGHPUT \(Int(Double(body.count) / secs / 1_000_000)) MB/s (\(r))")
        try? FileManager.default.removeItem(at: dest)
        server.stop()
    }
}
