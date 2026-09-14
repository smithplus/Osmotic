import Darwin
import Foundation
@testable import OsmoticCore

/// A loopback stand-in for an Osmo camera's datalink, faithful to the behaviours the session depends
/// on: the handshake echo, ~10 Hz `0x02/0x80` status pushes carrying the playback bit, the Pocket 3's
/// refusal of `0x02/0x0c` and its `0x01/0x01` playback entry, and the chunked `0x00/0x27` manifest
/// answer per request counter (start / data… / end, or start-only for an empty store).
final class FakeCamera: @unchecked Sendable {
    let port: UInt16
    private let manifest: [UInt8]
    private let olderPage: [UInt8]?
    private let refusePlaybackCommand: Bool
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
    private var seq = 0x2000

    init(manifest: [UInt8], olderPage: [UInt8]? = nil, refusePlaybackCommand: Bool) throws {
        self.manifest = manifest
        self.olderPage = olderPage
        self.refusePlaybackCommand = refusePlaybackCommand
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
                var flags = [UInt8](repeating: 0, count: 60)
                flags[0] = 0x01
                if playback { flags[3] = 0x40 }
                sendFrame(set: 0x02, cmd: 0x80, payload: flags, flags: 0x00, pktType: 0x01)
            }
        }
    }

    private func handle(_ pkt: [UInt8]) {
        guard pkt.count >= 8 else { return }
        switch pkt[6] {
        case 0x00:
            handshakes += 1
            send(DatalinkHeaders.udpHeader(pktType: 0x00, payloadLen: 1, sessionId: pkt.u16le(2), seq: 0) + [0x01])
        case 0x05:
            guard pkt.count > 20, let m = DjiMessage(frame: Array(pkt[20...])) else { return }
            command(m)
        default:
            break
        }
    }

    private func command(_ m: DjiMessage) {
        switch (m.cmdSet, m.cmdId) {
        case (0x02, 0x0C):
            if m.payload == [1, 1, 0, 0] { leaveReceived = true; playback = false; reply(m, [0x00]); return }
            if refusePlaybackCommand { reply(m, [0xE0]) } else { playback = true; reply(m, [0x00]) }
        case (0x01, 0x01):
            if m.payload.first == 0x00 {
                enterFrames += 1
                if enterFrames >= 5 { playback = true }
            }
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
        wrap(frame, pktType: 0x05)
    }

    private func sendFrame(set: Int, cmd: Int, payload: [UInt8], flags: Int, pktType: Int) {
        let frame = DjiMessage(target: 0x0201, id: 0x1000, type: flags | (set << 8) | (cmd << 16), payload: payload).encode()
        wrap(frame, pktType: pktType)
    }

    private func wrap(_ frame: [UInt8], pktType: Int) {
        seq = (seq + 8) & 0xFFFF
        let rt = LE.u16(seq) + LE.u16(seq) + [0, 0, 0, 0, 0, 1, 0, 0]
        send(DatalinkHeaders.udpHeader(pktType: pktType, payloadLen: rt.count + frame.count, sessionId: 0x1234, seq: seq) + rt + frame)
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
