import Darwin
import Foundation

@testable import OsmoticCore

/// A loopback stand-in for an Osmo camera's datalink, faithful to the behaviours the session depends
/// on: the handshake echo, ~10 Hz `0x02/0x80` status pushes carrying the playback bit, the Pocket 3's
/// refusal of `0x02/0x0c` and its `0x01/0x01` playback entry, and the chunked `0x00/0x27` manifest
/// answer per request counter (start / data… / end, or start-only for an empty store).
///
/// Capture side (behaviour chosen to match docs/CONTROL.md; the real Pocket 3 is unverified on some):
/// `0x01/0x01 03…07 01` frames enter playback after five, the live-view START (`01…05 01`) leaves it,
/// `0x02/0x0c 01 01 00 00` leaves it when `leaveExitsPlayback`; record/photo/mode follow the
/// camera's state machine and reply codes; `0x09/0xA8` outside playback starts an H.264 stream as
/// fragmented pktType-0x02 datagrams. Replies ride pktType 0x03, as on the camera.
final class FakeCamera: @unchecked Sendable {
    let port: UInt16
    private let manifest: [UInt8]
    private let olderPage: [UInt8]?
    private let refusePlaybackCommand: Bool
    private let leaveExitsPlayback: Bool
    private var fd: Int32 = -1
    private var client = sockaddr_in()
    private var hasClient = false
    private var thread: Thread?
    private let lock = NSLock()
    private var stopped = false

    private(set) var playback = false
    private(set) var enterFrames = 0
    private(set) var listQueries: [Int] = []
    private(set) var sdCursors: [Int] = []
    private(set) var handshakes = 0
    private(set) var leaveReceived = false
    private(set) var startFrames = 0
    private(set) var recState: UInt8 = 0x01  // 01 idle, 41 starting, 81 recording, C1 stopping
    private(set) var mode: UInt8 = 0x01  // video
    private(set) var photos = 0
    private(set) var videoRequests: [Int] = []  // receiver byte of each 0x09/0xA8
    private(set) var streaming = false
    private var recChangedAt = Date()
    private var recStartedAt = Date()
    private var videoSeq = 0x6000
    private var frameNo = 0
    private var lastClientSeq = 0
    private var seq = 0x2000

    init(manifest: [UInt8], olderPage: [UInt8]? = nil, refusePlaybackCommand: Bool, leaveExitsPlayback: Bool = true) throws {
        self.manifest = manifest
        self.olderPage = olderPage
        self.refusePlaybackCommand = refusePlaybackCommand
        self.leaveExitsPlayback = leaveExitsPlayback
        let s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard r == 0 else { throw DatalinkError.socket(errno) }
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) }
        }
        port = UInt16(bigEndian: bound.sin_port)
        var tv = timeval(tv_sec: 0, tv_usec: 50_000)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        fd = s
        let t = Thread { self.run() }
        thread = t
        t.start()
    }

    func stop() {
        lock.withLock { stopped = true }
        Thread.sleep(forTimeInterval: 0.1)
        close(fd)
    }

    private func run() {
        var buf = [UInt8](repeating: 0, count: 65536)
        var lastStatus = Date.distantPast
        while !lock.withLock({ stopped }) {
            var from = sockaddr_in()
            var flen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = buf.withUnsafeMutableBytes { b in
                withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, b.baseAddress, b.count, 0, $0, &flen) }
                }
            }
            if n > 0 {
                client = from
                hasClient = true
                handle(Array(buf[0..<n]))
            }
            if hasClient && Date().timeIntervalSince(lastStatus) > 0.1 {
                lastStatus = Date()
                advanceRecording()
                var flags = [UInt8](repeating: 0, count: 60)
                flags[0] = recState
                if playback { flags[3] = 0x40 }
                flags[4] = mode == 0x05 ? 0 : 1
                let elapsed = recState == 0x81 ? Int(Date().timeIntervalSince(recStartedAt)) : 0
                flags[29] = UInt8(elapsed & 0xFF); flags[30] = UInt8(elapsed >> 8)
                flags[57] = mode
                sendFrame(set: 0x02, cmd: 0x80, payload: flags, flags: 0x00, pktType: 0x01)
                // The 34-byte window status: @24 is the camera's ack of our client's last packet.
                var window = DatalinkHeaders.udpHeader(pktType: 0x01, payloadLen: 26, sessionId: 0x1234, seq: 0)
                window += [UInt8](repeating: 0, count: 26)
                window[24] = UInt8(lastClientSeq & 0xFF); window[25] = UInt8(lastClientSeq >> 8)
                send(window)
            }
            if streaming && hasClient { streamFrame() }
        }
    }

    private func handle(_ pkt: [UInt8]) {
        guard pkt.count >= 8 else { return }
        switch pkt[6] {
        case 0x00:
            handshakes += 1
            send(DatalinkHeaders.udpHeader(pktType: 0x00, payloadLen: 1, sessionId: pkt.u16le(2), seq: 0) + [0x01])
        case 0x05:
            lastClientSeq = pkt.u16le(4)
            guard pkt.count > 20, let m = DjiMessage(frame: Array(pkt[20...])) else { return }
            command(m)
        default:
            break
        }
    }

    private func command(_ m: DjiMessage) {
        switch (m.cmdSet, m.cmdId) {
        case (0x02, 0x0C):
            if m.payload == [1, 1, 0, 0] {
                leaveReceived = true
                if leaveExitsPlayback { playback = false; reply(m, [0x00]) } else { reply(m, [0xE0]) }
                return
            }
            if refusePlaybackCommand { reply(m, [0xE0]) } else { playback = true; reply(m, [0x00]) }
        case (0x01, 0x01):
            switch m.payload.first {
            case 0x03:  // playback prelude
                enterFrames += 1
                if enterFrames >= 5 { playback = true }
            case 0x01:  // live-view START: back to capture
                startFrames += 1
                playback = false
                enterFrames = 0
            default:
                break  // IDLE / hold
            }
        case (0x02, 0x02):
            guard !playback else { reply(m, [0xD9]); return }
            let start = m.payload.first == 0x01
            let recording = recState & 0x80 != 0
            if start == recording { reply(m, [0xDF]); return }
            recState = start ? 0x41 : 0xC1
            recChangedAt = Date()
            reply(m, [0x00])
        case (0x02, 0x01):
            guard !playback, mode == 0x05 else { reply(m, [0xD9]); return }
            photos += 1
            reply(m, [0x00])
        case (0x02, 0xE1):
            guard !playback, recState == 0x01, let code = m.payload.first else { reply(m, [0xD9]); return }
            mode = code
            reply(m, [0x00])
        case (0x09, 0xA8):
            videoRequests.append((m.target >> 8) & 0xFF)
            guard !playback else { reply(m, [0xE0]); return }
            streaming = true
            frameNo = 0
            reply(m, [0x00])
        case (0x00, 0x26):
            let p = m.payload
            guard p.count > 4, p[0] == 0x4A else { return }
            if p[1] == 0x00 {
                let ctr = Int(p[4])
                let cursor = p.u32le(10)
                listQueries.append(ctr)
                if ctr == 1 { sdCursors.append(cursor) }
                let sdAnswer = cursor == 1 ? manifest : (olderPage ?? manifest)
                streamManifest(ctr: ctr, data: ctr == 1 ? sdAnswer : [])
            }
        default:
            reply(m, [0x00])
        }
    }

    private func streamManifest(ctr: Int, data: [UInt8]) {
        func sub(_ kind: UInt8, _ s: Int) -> [UInt8] { [0x4A, kind, 0, 0, UInt8(ctr), 0] + LE.u16(s) + [0, 0] }
        sendFrame(set: 0x00, cmd: 0x27, payload: sub(0x04, 0), flags: 0x00, pktType: 0x01)
        guard !data.isEmpty else { return }
        var s = 0
        var i = 0
        while i < data.count {
            let chunk = Array(data[i..<min(i + 800, data.count)])
            sendFrame(set: 0x00, cmd: 0x27, payload: sub(0x01, s) + chunk, flags: 0x00, pktType: 0x01)
            i += 800
            s += 1
        }
        sendFrame(set: 0x00, cmd: 0x27, payload: sub(0x03, s), flags: 0x00, pktType: 0x01)
    }

    private func reply(_ m: DjiMessage, _ payload: [UInt8]) {
        let swapped = ((m.target & 0xFF) << 8) | ((m.target >> 8) & 0xFF)
        let frame = DjiMessage(target: swapped, id: m.id, type: (m.type & 0xFFFF00) | 0xC0, payload: payload).encode()
        wrap(frame, pktType: 0x03)
    }

    private func sendFrame(set: Int, cmd: Int, payload: [UInt8], flags: Int, pktType: Int) {
        let frame = DjiMessage(target: 0x0201, id: 0x1000, type: flags | (set << 8) | (cmd << 16), payload: payload).encode()
        wrap(frame, pktType: pktType)
    }

    private func wrap(_ frame: [UInt8], pktType: Int) {
        seq = (seq + 8) & 0xFFFF
        let rt = LE.u16(seq) + LE.u16(seq) + [0, 0, 0, 0, 0, 1, 0, 0]
        send(
            DatalinkHeaders.udpHeader(pktType: pktType, payloadLen: rt.count + frame.count, sessionId: 0x1234, seq: seq) + rt
                + frame)
    }

    /// 01 → 41 → 81 on start, 81 → C1 → 01 on stop, 300 ms in between.
    private func advanceRecording() {
        guard Date().timeIntervalSince(recChangedAt) > 0.3 else { return }
        if recState == 0x41 { recState = 0x81; recStartedAt = Date() }
        if recState == 0xC1 { recState = 0x01 }
    }

    /// One live-view message per tick: SPS+PPS+IDR first, then P slices, fragmented at 1400 bytes.
    static let sps: [UInt8] = [0x67, 0x64, 0x00, 0x1F, 0xAC, 0xD9, 0x40]
    static let pps: [UInt8] = [0x68, 0xEE, 0x3C, 0x80]
    static func accessUnit(_ n: Int) -> [UInt8] {
        let body = [UInt8](repeating: UInt8(truncatingIfNeeded: n), count: n == 0 ? 3000 : 900)
        if n == 0 { return [0, 0, 0, 1] + sps + [0, 0, 0, 1] + pps + [0, 0, 0, 1, 0x65] + body }
        return [0, 0, 0, 1, 0x41] + body
    }

    private func streamFrame() {
        let au = Self.accessUnit(frameNo)
        frameNo += 1
        var message: [UInt8] = [0, 0, 1, 0xFF] + LE.u32(au.count) + [UInt8](repeating: 0, count: 8) + au
        while !message.isEmpty {
            let piece = Array(message.prefix(1400))
            message.removeFirst(piece.count)
            videoSeq = (videoSeq + 8) & 0xFFFF
            send(
                DatalinkHeaders.udpHeader(pktType: 0x02, payloadLen: 12 + piece.count, sessionId: 0x1234, seq: videoSeq)
                    + [UInt8](repeating: 0, count: 12) + piece)
        }
    }

    private func send(_ pkt: [UInt8]) {
        guard hasClient else { return }
        var to = client
        _ = pkt.withUnsafeBytes { b in
            withUnsafePointer(to: &to) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, b.baseAddress, b.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }
}
