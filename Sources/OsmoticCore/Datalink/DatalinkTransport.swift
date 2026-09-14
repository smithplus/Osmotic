import Darwin
import Foundation

/// Pure builders for the datalink wire headers. Each UDP packet is
/// `[8B transport hdr][12B routing hdr][DUML frame]`.
public enum DatalinkHeaders {
    /// `[u16 0x8000|total][u16 session][u16 seq][u8 pktType][u8 xor-of-previous-7]`.
    public static func udpHeader(pktType: Int, payloadLen: Int, sessionId: Int, seq: Int) -> [UInt8] {
        let total = 8 + payloadLen
        let w0 = (1 << 15) | (total & 0x3FFF)
        var b: [UInt8] = LE.u16(w0) + LE.u16(sessionId) + LE.u16(seq) + [UInt8(pktType & 0xFF)]
        b.append(b.reduce(0, ^))
        return b
    }

    /// `[ack : u16][seq : u16] 00 00 00 00 [counter] 01 [00|60] 00`. `ack` is the camera's
    /// acknowledgement of our last packet when known (`peerAck`, the official app's model), else
    /// `seq - 8` (the model media listing was proven with). Getting it wrong silently drops writes.
    public static func routingHeader(seq: Int, peerAck: Int? = nil, cmdCounter: Int, drone: Bool) -> [UInt8] {
        let ack = (peerAck ?? (seq - 8)) & 0xFFFF
        return LE.u16(ack) + LE.u16(seq) + [0, 0, 0, 0, UInt8(cmdCounter & 0xFF), 0x01, drone ? 0x60 : 0x00, 0x00]
    }

    /// The official app's pktType-0x04 window ACK: latest video seq, latest command-reply seq, then the
    /// camera's ack of our TX and our last TX seq. Adapted from Kaze for DJI (MIT), `DumlFraming`.
    public static func windowAck(rxVideo: Int, rxReply: Int, peerAckedTx: Int, lastTx: Int) -> [UInt8] {
        func pair(_ a: Int, _ b: Int) -> [UInt8] { LE.u16(a) + LE.u16(b) + [0, 0, 0, 0] }
        return pair(rxVideo, rxVideo) + pair(rxReply, rxReply) + pair(peerAckedTx, lastTx) + [0, 0]
    }

    /// The pktType-0x00 SYN: our proposed base sequence, then the window/MTU parameters the official
    /// app offers, replayed verbatim.
    public static func handshakePayload(baseSeq: Int) -> [UInt8] {
        var p = [UInt8](hex: "000064006400c005140000640000019001c005140000640014006400c00514000064000101040102")
        p[0] = UInt8(baseSeq & 0xFF)
        p[1] = UInt8((baseSeq >> 8) & 0xFF)
        return p
    }
}

/// The DUML-over-UDP datalink: socket, session, sequencing and framing. Blocking; every call must come
/// from the single thread that owns the session (see `CameraSession`).
public final class DatalinkTransport {
    public let port: UInt16
    private let log: (String) -> Void
    private let interfaceName: String?

    public private(set) var sessionId = 0
    private var udpSeq = 0
    private var dumlSeq = 0xA000
    private var cmdCounter = 0
    public private(set) var cameraChannel = 0
    public private(set) var baseSeq = 0
    private var peerCursor = 0
    private var peerDownloadCursor = 0

    /// How our packets acknowledge the camera's windows. `.legacy`: routing ack `seq-8`, ACK groups from
    /// the camera's status packet (media listing and downloads were proven with it). `.mimo`: what the
    /// official app does — needed for capture commands and live view, where replies ride pktType 0x03
    /// and must be echoed or they stop. See `docs/CONTROL.md`.
    public enum WindowModel: Sendable { case legacy, mimo }
    public var windowModel: WindowModel = .legacy

    // Window cursors, learned from every datagram (port of Kaze's `observeTransportState`, MIT).
    public private(set) var rxVideoSeq = 0
    public private(set) var rxReplySeq = 0
    public private(set) var peerAckedTxSeq = 0
    public private(set) var lastTxSeq = 0
    private var seenVideo = false
    private var seenReply = false

    /// pktType-0x02 (live-view) datagrams go here instead of being returned by `recvAll`, so video
    /// bytes can never be mistaken for status frames. Runs on the receiving (session) thread.
    public var onVideo: (([UInt8]) -> Void)?
    /// With no `onVideo`, still drop pktType 0x02 (after live view, stray fragments keep arriving).
    public var dropVideo = false

    private var fd: Int32 = -1
    /// Checked inside the blocking loops so a closing session doesn't wait out a handshake or a receive.
    public var shouldAbort: () -> Bool = { false }
    private var peer = sockaddr_in()
    public private(set) var peerIp = ""

    public init(port: UInt16, interfaceName: String? = nil, log: @escaping (String) -> Void) {
        self.port = port
        self.interfaceName = interfaceName
        self.log = log
    }

    deinit { close() }

    public var isOpen: Bool { fd >= 0 }

    // ---- lifecycle ------------------------------------------------------------------------------

    /// Create the socket and pick a session id and a fresh random base sequence.
    public func open(ip: String) throws {
        close()
        let s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard s >= 0 else { throw DatalinkError.socket(errno) }
        var tv = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var bufSize: Int32 = 4 << 20
        setsockopt(s, SOL_SOCKET, SO_RCVBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        Self.bindToInterface(s, interfaceName, log: log)
        fd = s
        peer = sockaddr_in()
        peer.sin_family = sa_family_t(AF_INET)
        peer.sin_port = port.bigEndian
        inet_pton(AF_INET, ip, &peer.sin_addr)
        peerIp = ip
        sessionId = Int.random(in: 0x1000..<0xFFFE)
        baseSeq = Int.random(in: 0x1000..<0xF000) & 0xFFF8
        cameraChannel = baseSeq
        rxVideoSeq = baseSeq; rxReplySeq = baseSeq; peerAckedTxSeq = baseSeq; lastTxSeq = baseSeq
        seenVideo = false; seenReply = false
        udpSeq = 0
        cmdCounter = 0
        dumlSeq = 0xA000
        peerCursor = 0
        peerDownloadCursor = 0
    }

    public func close() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }

    /// Pin a socket to the Wi-Fi interface so camera traffic never leaves by Ethernet.
    static func bindToInterface(_ s: Int32, _ name: String?, log: (String) -> Void) {
        guard let name else { return }
        var index = if_nametoindex(name)
        guard index != 0 else { return }
        if setsockopt(s, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size)) != 0 {
            log("datalink: could not bind to \(name) (errno \(errno))")
        }
    }

    /// Send the SYN until the peer answers with a pktType-0x00 frame. Nil if nothing ever came back —
    /// how the caller tells "wrong UDP port" apart from "no media".
    public func handshake(attempts: Int = 20) -> [UInt8]? {
        let payload = DatalinkHeaders.handshakePayload(baseSeq: baseSeq)
        for _ in 0..<attempts {
            if shouldAbort() { return nil }
            sendRaw(pktType: 0x00, payload: payload)
            for r in recvAll(ms: 350) where r.count >= 8 && r[6] == 0x00 { return r }
        }
        return nil
    }

    /// Start our send sequence at the peer's channel + 8.
    public func syncSeqToPeerChannel() {
        udpSeq = (cameraChannel + 8) & 0xFFFF
        lastTxSeq = cameraChannel
        peerAckedTxSeq = cameraChannel
    }

    /// Our packets the camera hasn't acknowledged yet (a growing number means writes are being lost).
    public var txLagSlots: Int { ((lastTxSeq - peerAckedTxSeq) & 0xFFFF) / 8 }

    // ---- send -----------------------------------------------------------------------------------

    @discardableResult
    private func sendPacket(_ pkt: [UInt8]) -> Bool {
        guard fd >= 0 else { return false }
        var addr = peer
        let n = pkt.withUnsafeBytes { buf in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return n == pkt.count
    }

    public func sendRaw(pktType: Int, payload: [UInt8]) {
        let pkt = DatalinkHeaders.udpHeader(pktType: pktType, payloadLen: payload.count, sessionId: sessionId, seq: udpSeq) + payload
        if sendPacket(pkt) {
            if pktType != 0x00 { lastTxSeq = udpSeq }
            advance()
        }
    }

    /// The pktType-0x04 window acknowledgement: video, download and control windows. Echoing the
    /// peer's download cursor is what keeps a long manifest streaming to its end.
    public func sendAck() {
        func group(_ v: Int) -> [UInt8] { LE.u16(v) + LE.u16(v) + [0, 0, 0, 0] }
        let payload = windowModel == .mimo
            ? DatalinkHeaders.windowAck(rxVideo: rxVideoSeq, rxReply: rxReplySeq, peerAckedTx: peerAckedTxSeq, lastTx: lastTxSeq)
            : group(peerCursor) + group(peerDownloadCursor) + group(baseSeq) + [0, 0]
        let hdr = DatalinkHeaders.udpHeader(pktType: 0x04, payloadLen: payload.count, sessionId: sessionId, seq: 0)
        sendPacket(hdr + payload)
    }

    /// A command frame: receiver byte `(receiverId << 5) | receiverType`, sender App(0x02).
    public func sendDuml(set: Int, cmd: Int, payload: [UInt8], receiverType: Int, receiverId: Int, cmdType: Int = 2) {
        cmdCounter += 1
        let rt = DatalinkHeaders.routingHeader(seq: udpSeq, peerAck: windowModel == .mimo ? peerAckedTxSeq : nil,
                                               cmdCounter: cmdCounter, drone: false)
        let target = 0x02 | (((receiverId << 5) | receiverType) << 8)
        let type = (cmdType << 5) | (set << 8) | (cmd << 16)
        let duml = DjiMessage(target: target, id: dumlSeq, type: type, payload: payload).encode()
        dumlSeq = (dumlSeq + 1) & 0xFFFF
        let pkt = DatalinkHeaders.udpHeader(pktType: 0x05, payloadLen: rt.count + duml.count, sessionId: sessionId, seq: udpSeq) + rt + duml
        if sendPacket(pkt) {
            lastTxSeq = udpSeq
            advance()
        }
    }

    private func advance() { udpSeq = (udpSeq + 8) & 0xFFFF }

    // ---- receive --------------------------------------------------------------------------------

    /// Every datagram that arrives within `ms`. Learns the peer's channel and window cursors as it goes.
    public func recvAll(ms: Int, precise: Bool = false) -> [[UInt8]] {
        guard fd >= 0 else {
            if !shouldAbort() { Thread.sleep(forTimeInterval: Double(ms) / 1000) }
            return []
        }
        var out: [[UInt8]] = []
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(ms) * 1_000_000
        var buf = [UInt8](repeating: 0, count: 65536)
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if shouldAbort() { break }
            // `precise` (the control pump's 12 ms bursts) waits only as long as the call has left. The
            // media flows rely on the socket's coarse 200 ms timeout for their pacing (a short receive
            // there doubles as a gap between sends, tuned on hardware), so they keep it.
            if precise {
                let left = Int((deadline - min(deadline, DispatchTime.now().uptimeNanoseconds)) / 1_000_000)
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                if poll(&pfd, 1, Int32(max(1, left))) <= 0 { continue }
            }
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = buf.withUnsafeMutableBytes { b in
                withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, b.baseAddress, b.count, 0, $0, &fromLen) }
                }
            }
            if n < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
                // A dying link (AP gone) — back off instead of spinning.
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            // Only the camera speaks on this socket: anyone else on its network is ignored.
            guard from.sin_addr.s_addr == peer.sin_addr.s_addr else { continue }
            let data = Array(buf[0..<n])
            observe(data)
            if data.count >= 8 && data[6] == 0x02 {
                if let onVideo { onVideo(data); continue }
                if dropVideo { continue }
            }
            out.append(data)
        }
        return out
    }

    /// Learn the peer's channel and window cursors from one datagram. Video (0x02) and reply (0x03)
    /// seqs come from those packets themselves once seen; the 34-byte status packet only seeds them
    /// and never rewinds them. Adapted from Kaze for DJI (MIT), `DumlTransport.observeTransportState`.
    private func observe(_ d: [UInt8]) {
        guard d.count >= 8 else { return }
        let type = d[6]
        let seq = d.u16le(4)
        // Video fragments reuse bytes 8-9 for their own header: never learn the channel from them.
        if d.count >= 10, type != 0x02 {
            let ch = d.u16le(8)
            if ch != 0 { cameraChannel = ch }
        }
        if seq != 0 {
            if type == 0x02 { rxVideoSeq = seq; seenVideo = true }
            if type == 0x03 { rxReplySeq = seq; seenReply = true }
        }
        if type == 0x01 && d.count == 34 {
            peerCursor = d.u16le(10)
            peerDownloadCursor = d.u16le(18)
            if !seenVideo, d.u16le(10) != 0 { rxVideoSeq = d.u16le(10) }
            if !seenReply, d.u16le(18) != 0 { rxReplySeq = d.u16le(18) }
            if d.u16le(24) != 0 { peerAckedTxSeq = d.u16le(24) }
        }
    }
}

public enum DatalinkError: Error, CustomStringConvertible {
    case socket(Int32)

    public var description: String {
        switch self {
        case .socket(let e): "socket() failed: \(String(cString: strerror(e)))"
        }
    }
}

/// One-shot TCP connect with a timeout, used for the TCP-7001 poke and for reachability checks.
public enum TCPProbe {
    /// Connect to `ip:port` within `timeout`; optionally write `payload` and hold for `hold` seconds.
    @discardableResult
    public static func connect(ip: String, port: UInt16, timeout: TimeInterval, payload: [UInt8]? = nil,
                               hold: TimeInterval = 0, interfaceName: String? = nil) -> Bool {
        let s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard s >= 0 else { return false }
        defer { Darwin.close(s) }
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        DatalinkTransport.bindToInterface(s, interfaceName, log: { _ in })
        let flags = fcntl(s, F_GETFL, 0)
        _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, ip, &addr.sin_addr)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if r != 0 && errno != EINPROGRESS { return false }
        if r != 0 {
            var pfd = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
            guard poll(&pfd, 1, Int32(timeout * 1000)) == 1 else { return false }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &len)
            guard err == 0 else { return false }
        }
        _ = fcntl(s, F_SETFL, flags)
        if let payload {
            _ = payload.withUnsafeBytes { send(s, $0.baseAddress, $0.count, 0) }
        }
        if hold > 0 { Thread.sleep(forTimeInterval: hold) }
        return true
    }

}
