import Foundation
import Testing

@testable import OsmoticCore

/// Byte-level vectors for the capture/live-view transport (Kaze for DJI's published test vectors).
@Suite struct ControlProtocolTests {
    @Test func `routing header carries the camera's ack of our tx when known`() {
        let rt = DatalinkHeaders.routingHeader(seq: 0x5678, peerAck: 0x1234, cmdCounter: 0x9A, drone: false)
        #expect(rt.hexString.lowercased() == "34127856000000009a010000")
        // Without it, the media model's seq-8 stays exactly as before.
        #expect(
            DatalinkHeaders.routingHeader(seq: 0x5678, cmdCounter: 0x9A, drone: false).hexString.lowercased()
                == "70567856000000009a010000")
    }

    @Test func `window ack echoes video, reply and tx windows`() {
        let ack = DatalinkHeaders.windowAck(rxVideo: 0x1111, rxReply: 0x2222, peerAckedTx: 0x3333, lastTx: 0x4444)
        #expect(ack.hexString.lowercased() == "1111111100000000222222220000000033334444000000000000")
    }

    @Test func `status push carries recording state, elapsed time and mode`() {
        var tracker = StatusTracker()
        var p = [UInt8](repeating: 0, count: 60)
        p[0] = 0x81; p[4] = 1; p[29] = 12; p[57] = 0x01
        tracker.apply(set: 0x02, id: 0x80, payload: p, log: { _ in })
        #expect(tracker.status.recording && !tracker.status.recordingTransition)
        #expect(tracker.status.recordingSeconds == 12)
        #expect(tracker.status.captureMode == .video)
        p[0] = 0xC1
        tracker.apply(set: 0x02, id: 0x80, payload: p, log: { _ in })
        #expect(tracker.status.recording && tracker.status.recordingTransition)
        p[0] = 0x01; p[4] = 0; p[57] = 0x05
        tracker.apply(set: 0x02, id: 0x80, payload: p, log: { _ in })
        #expect(!tracker.status.recording && tracker.status.recordingSeconds == 0)
        #expect(tracker.status.captureMode == .photo)
    }
}

@Suite struct LiveReassemblerTests {
    func datagram(seq: Int, _ payload: [UInt8]) -> [UInt8] {
        DatalinkHeaders.udpHeader(pktType: 0x02, payloadLen: 12 + payload.count, sessionId: 1, seq: seq)
            + [UInt8](repeating: 0, count: 12) + payload
    }

    func message(_ body: [UInt8]) -> [UInt8] { [0, 0, 1, 0xFF] + LE.u32(body.count) + [UInt8](repeating: 9, count: 8) + body }

    @Test func `a single fragment message`() {
        var r = LiveReassembler()
        let body: [UInt8] = [0, 0, 0, 1, 0x65, 1, 2, 3]
        #expect(r.feed(datagram(seq: 8, message(body)), now: 0) == body)
    }

    @Test func `fragments join in seq order`() {
        var r = LiveReassembler()
        let body = [UInt8]((0..<3000).map { UInt8($0 & 0xFF) })
        let m = message(body)
        #expect(r.feed(datagram(seq: 8, Array(m[0..<1400])), now: 0) == nil)
        #expect(r.feed(datagram(seq: 16, Array(m[1400..<2800])), now: 0) == nil)
        #expect(r.feed(datagram(seq: 24, Array(m[2800...])), now: 0) == body)
    }

    @Test func `a missing fragment drops the message, not the stream`() {
        var r = LiveReassembler()
        let m = message([UInt8](repeating: 7, count: 3000))
        _ = r.feed(datagram(seq: 8, Array(m[0..<1400])), now: 0)
        #expect(r.feed(datagram(seq: 24, Array(m[2800...])), now: 0) == nil)  // seq 16 lost: counted, not trusted
        #expect(r.gaps == 1)
        let next: [UInt8] = [0, 0, 0, 1, 0x41, 5]
        #expect(r.feed(datagram(seq: 32, message(next)), now: 0) == next)
        #expect(r.dropped == 1, "the short message is dropped when the next one starts")
    }

    @Test func `joining mid-message waits for the next start`() {
        var r = LiveReassembler()
        #expect(r.feed(datagram(seq: 8, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17]), now: 0) == nil)
        #expect(r.dropped == 0)
    }

    @Test func `absurd lengths are rejected`() {
        var r = LiveReassembler()
        #expect(
            r.feed(
                datagram(seq: 8, [0, 0, 1, 0xFF] + LE.u32(LiveReassembler.maxMessage + 1) + [UInt8](repeating: 0, count: 12)),
                now: 0) == nil)
        #expect(r.invalid == 1)
    }
}

final class VideoSink: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [[UInt8]] = []
    func add(_ m: [UInt8]) { lock.withLock { messages.append(m) } }
    var all: [[UInt8]] { lock.withLock { messages } }
}

/// Capture mode against `FakeCamera`: leave playback, record, mode, photo, live view, back to the card.
@Suite(.serialized) struct ControlEndToEndTests {
    func session(_ cam: FakeCamera, _ sink: LogSink) -> CameraSession {
        var model = CameraModel.resolve(modelId: 0x0020, name: "OsmoPocket3")
        model.datalinkPort = cam.port
        model.tcpPoke = false
        return CameraSession(ip: "127.0.0.1", model: model, interfaceName: nil, log: { sink.add($0) })
    }

    @Test(.timeLimit(.minutes(1)))
    func `capture commands, then back to the card`() async throws {
        let cam = try FakeCamera(manifest: try fixture("op3_29.bin"), refusePlaybackCommand: true)
        defer { cam.stop() }
        let sink = LogSink()
        let s = session(cam, sink)
        let listed = await s.connect()
        #expect(listed.handshakeOk && cam.playback)

        #expect(await s.enterControl())
        #expect(!cam.playback)
        let controlLines = sink.all.filter { $0.contains("control:") || $0.contains("playback mode") }
        #expect(sink.all.contains { $0.contains("out of playback (0x02/0x0c") }, "\(controlLines)")

        #expect(await s.setRecording(true))
        #expect(cam.recState == 0x81)
        #expect(await s.setRecording(false))
        #expect(cam.recState == 0x01)

        #expect(await s.takePhoto() == false, "photo in video mode is refused (D9)")
        #expect(await s.setMode(.photo))
        #expect(cam.mode == 0x05)
        #expect(await s.takePhoto())
        #expect(cam.photos == 1)

        let back = await s.leaveControl()
        #expect(cam.playback)
        #expect(back?.files.count == ManifestDecoder.decode(try fixture("op3_29.bin")).count)
        await s.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func `a visit to Live keeps the card's paging where it was`() async throws {
        let cam = try FakeCamera(
            manifest: try fixture("oa4_45.bin"), olderPage: try fixture("op3_15.bin"), refusePlaybackCommand: true)
        defer { cam.stop() }
        let sink = LogSink()
        let s = session(cam, sink)
        let first = await s.connect()
        #expect(first.files.count == 45 && first.moreAvailable)

        #expect(await s.enterControl())
        let during = await s.nextPage()
        #expect(during.files.isEmpty && during.moreAvailable, "out of playback: nothing now, but not the end")

        let back = await s.leaveControl()
        #expect(back?.files.count == 45)
        #expect(back?.moreAvailable == true)
        let older = await s.nextPage()
        #expect(older.files.count == 15, "paging carries on from page one's cursor")
        await s.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func `when 0x02-0x0c can't leave playback, the live START burst does`() async throws {
        let cam = try FakeCamera(manifest: try fixture("op3_15.bin"), refusePlaybackCommand: true, leaveExitsPlayback: false)
        defer { cam.stop() }
        let sink = LogSink()
        let s = session(cam, sink)
        _ = await s.connect()
        #expect(await s.enterControl())
        #expect(!cam.playback && cam.startFrames > 0)
        #expect(sink.all.contains { $0.contains("out of playback (0x01/0x01 START)") })
        await s.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func `live view arrives as whole H.264 messages`() async throws {
        let cam = try FakeCamera(manifest: try fixture("op3_15.bin"), refusePlaybackCommand: true)
        defer { cam.stop() }
        let sink = LogSink()
        let s = session(cam, sink)
        _ = await s.connect()
        let video = VideoSink()
        #expect(await s.startLiveView { video.add($0) })
        for _ in 0..<60 where video.all.count < 5 { try await Task.sleep(for: .milliseconds(100)) }
        let got = video.all
        #expect(got.count >= 5)
        #expect(cam.videoRequests.contains(0x41), "Kaze's request goes to receiver 0x41")
        if let first = got.first {
            #expect(H264AnnexB.units(first).map(H264AnnexB.type) == [7, 8, 5])
            #expect(first.count == FakeCamera.accessUnit(0).count && first.prefix(24) == FakeCamera.accessUnit(0).prefix(24))
        }
        if got.count > 1 { #expect(got[1].count == FakeCamera.accessUnit(1).count && got[1].last == 1) }
        await s.stopLiveView()
        await s.close()
    }
}
