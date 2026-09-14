import Foundation
import Testing
@testable import OsmoticCore

final class LogSink: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ s: String) { lock.withLock { lines.append(s) } }
    var all: [String] { lock.withLock { lines } }
}

/// The whole camera session — handshake, registration, playback, list, keep-alive, teardown — run
/// against `FakeCamera` on loopback.
@Suite(.serialized) struct SessionEndToEndTests {
    @Test(.timeLimit(.minutes(1)))
    func `a pocket 3 session enters playback through 0x01-0x01 and lists the card`() async throws {
        let cam = try FakeCamera(manifest: try fixture("op3_29.bin"), refusePlaybackCommand: true)
        defer { cam.stop() }
        var model = CameraModel.resolve(modelId: 0x0020, name: "OsmoPocket3")
        model.datalinkPort = cam.port
        model.tcpPoke = false
        let sink = LogSink()
        let session = CameraSession(ip: "127.0.0.1", model: model, interfaceName: nil, log: { sink.add($0) })
        let result = await session.connect()

        #expect(result.handshakeOk)
        #expect(cam.playback, "the camera must end up in playback")
        #expect(cam.enterFrames >= 5, "via the Pocket 3's 0x01/0x01 route")
        #expect(cam.listQueries.contains(1) && cam.listQueries.contains(2))
        #expect(result.files.count == ManifestDecoder.decode(try fixture("op3_29.bin")).count)
        #expect(result.files.allSatisfy { $0.storageKnown && $0.storage == 0 })
        #expect(sink.all.contains { $0.contains("playback mode held via 0x01/0x01") })

        // Let a few keep-alive ticks run, then tear down: the leave must go out.
        try await Task.sleep(for: .seconds(1.5))
        await session.close()
        for _ in 0..<20 where !cam.leaveReceived { try await Task.sleep(for: .milliseconds(50)) }
        #expect(cam.leaveReceived)
    }

    @Test(.timeLimit(.minutes(1)))
    func `a camera that accepts 0x02-0x0c enters playback directly`() async throws {
        let cam = try FakeCamera(manifest: try fixture("op3_15.bin"), refusePlaybackCommand: false)
        defer { cam.stop() }
        var model = CameraModel.resolve(modelId: 0x0020, name: "OsmoPocket3")
        model.datalinkPort = cam.port
        model.tcpPoke = false
        let session = CameraSession(ip: "127.0.0.1", model: model, interfaceName: nil, log: { _ in })
        let result = await session.connect()
        #expect(result.handshakeOk)
        #expect(result.files.count == 15)
        #expect(cam.enterFrames == 0)
        await session.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func `a full card pages inline on the live session`() async throws {
        let cam = try FakeCamera(manifest: try fixture("oa4_45.bin"), olderPage: try fixture("op3_15.bin"),
                                 refusePlaybackCommand: true)
        defer { cam.stop() }
        var model = CameraModel.resolve(modelId: 0x0020, name: "OsmoPocket3")
        model.datalinkPort = cam.port
        model.tcpPoke = false
        let session = CameraSession(ip: "127.0.0.1", model: model, interfaceName: nil, log: { _ in })
        let first = await session.connect()
        #expect(first.files.count == 45)
        #expect(first.moreAvailable, "a full 45-record page must offer an older one")

        let page = await session.nextPage()
        #expect(page.files.count == 15)
        #expect(!page.moreAvailable, "a short final page ends the library")
        #expect(cam.sdCursors.contains(0x0004_00b0), "the cursor is the oldest SD handle of page one")
        #expect(cam.handshakes == 1, "paged inline — no fresh session")
        await session.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func `nothing listening means no handshake, on both ports`() async {
        var model = CameraModel.default
        model.datalinkPort = 1   // nothing answers here
        model.tcpPoke = false
        let session = CameraSession(ip: "127.0.0.1", model: model, interfaceName: nil, log: { _ in })
        let result = await session.connect()
        #expect(!result.handshakeOk)
        #expect(result.files.isEmpty)
        await session.close()
    }
}
