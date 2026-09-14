import Foundation

/// DJI DUML checksums, the same algorithm the drone-side DUML uses.
/// Ported from dji-remote's `DjiCrc` (MIT) via Osmosis.
public enum DjiCrc {
    /// CRC-8, reflected: init `0x77` (= reflect8(0xEE)), poly `0x8C` (= reflect8(0x31)).
    public static func crc8<C: Collection<UInt8>>(_ data: C) -> UInt8 {
        var crc: UInt8 = 0x77
        for b in data {
            crc ^= b
            for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0x8C : crc >> 1 }
        }
        return crc
    }

    /// CRC-16, reflected: init `0x3692` (= reflect16(0x496C)), poly `0x8408` (= reflect16(0x1021)).
    public static func crc16<C: Collection<UInt8>>(_ data: C) -> UInt16 {
        var crc: UInt16 = 0x3692
        for b in data {
            crc ^= UInt16(b)
            for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0x8408 : crc >> 1 }
        }
        return crc
    }
}

/// One DUML frame:
/// `55 | len(10 bits) + ver(6 bits) | crc8 | target:u16 | id:u16 | type:u24 | payload | crc16`.
///
/// `type` packs `flags | cmdSet << 8 | cmdId << 16` (flags `0x40` request, `0xC0` response, `0x00` push).
/// `target` packs the sender byte low and the receiver byte high; each is `(id << 5) | type`.
public struct DjiMessage: Sendable, Equatable {
    public var target: Int
    public var id: Int
    public var type: Int
    public var payload: [UInt8]

    public init(target: Int, id: Int, type: Int, payload: [UInt8]) {
        self.target = target
        self.id = id
        self.type = type
        self.payload = payload
    }

    public var flags: Int { type & 0xFF }
    public var cmdSet: Int { (type >> 8) & 0xFF }
    public var cmdId: Int { (type >> 16) & 0xFF }
    public var sender: Int { target & 0xFF }
    public var receiver: Int { (target >> 8) & 0xFF }

    public func encode() -> [UInt8] {
        let length = 13 + payload.count
        var out: [UInt8] = [0x55, UInt8(length & 0xFF), UInt8(0x04 | ((length >> 8) & 0x03))]
        out.reserveCapacity(length)
        out.append(DjiCrc.crc8(out))
        out += LE.u16(target)
        out += LE.u16(id)
        out += LE.u24(type)
        out += payload
        out += LE.u16(Int(DjiCrc.crc16(out)))
        return out
    }

    /// Decode exactly one frame occupying all of `data`, verifying length, version and both CRCs.
    public init?(frame data: [UInt8]) {
        guard data.count >= 13, data[0] == 0x55 else { return nil }
        let length = (Int(data[1]) | (Int(data[2]) << 8)) & 0x3FF
        guard length == data.count, data[2] >> 2 == 1 else { return nil }
        guard DjiCrc.crc8(data[0..<3]) == data[3] else { return nil }
        guard DjiCrc.crc16(data[0..<(length - 2)]) == UInt16(data.u16le(length - 2)) else { return nil }
        target = data.u16le(4)
        id = data.u16le(6)
        type = Int(data[8]) | (Int(data[9]) << 8) | (Int(data[10]) << 16)
        payload = Array(data[11..<(length - 2)])
    }

    public var summary: String {
        String(format: "target=0x%04X id=0x%04X flags=0x%02X set=0x%02X cmd=0x%02X payload=%@",
               target, id, flags, cmdSet, cmdId, payload.hexString)
    }
}

/// Every CRC-valid DUML frame inside a byte buffer, scanned one byte at a time so frames embedded in
/// transport headers, noise or tunnel frames are all found. Both CRCs are verified, which is what makes
/// byte-at-a-time scanning safe from false positives.
public enum DumlScanner {
    public struct Frame: Sendable {
        public let cmdSet: Int
        public let cmdId: Int
        public let payload: [UInt8]
        public let start: Int
        public let length: Int
    }

    public static func frames(in raw: [UInt8]) -> [Frame] {
        var out: [Frame] = []
        var i = 0
        while i + 13 <= raw.count {
            if let f = frame(in: raw, at: i, requireCrc16: true) { out.append(f) }
            i += 1
        }
        return out
    }

    /// A frame starting exactly at `i`, header CRC always verified.
    @inline(__always)
    static func frame(in raw: [UInt8], at i: Int, requireCrc16: Bool) -> Frame? {
        guard raw[i] == 0x55, i + 13 <= raw.count else { return nil }
        let len = (Int(raw[i + 1]) | (Int(raw[i + 2]) << 8)) & 0x3FF
        guard len >= 13, i + len <= raw.count else { return nil }
        guard DjiCrc.crc8(raw[i..<(i + 3)]) == raw[i + 3] else { return nil }
        if requireCrc16 {
            guard raw[i + 2] >> 2 == 1 else { return nil }
            let want = Int(raw[i + len - 2]) | (Int(raw[i + len - 1]) << 8)
            guard Int(DjiCrc.crc16(raw[i..<(i + len - 2)])) == want else { return nil }
        }
        return Frame(cmdSet: Int(raw[i + 9]), cmdId: Int(raw[i + 10]),
                     payload: Array(raw[(i + 11)..<(i + len - 2)]), start: i, length: len)
    }

    /// Walks frames by header CRC and hops frame-to-frame, the way the camera session's status and
    /// reply scans do. Cheaper than `frames(in:)` on large telemetry blobs.
    public static func walk(_ raw: [UInt8], _ body: (Frame) -> Void) {
        var i = 0
        while i + 11 <= raw.count {
            guard raw[i] == 0x55 else { i += 1; continue }
            let len = i + 2 < raw.count ? (Int(raw[i + 1]) | (Int(raw[i + 2]) << 8)) & 0x3FF : 0
            guard len >= 13, i + len <= raw.count,
                  DjiCrc.crc8(raw[i..<(i + 3)]) == raw[i + 3] else { i += 1; continue }
            body(Frame(cmdSet: Int(raw[i + 9]), cmdId: Int(raw[i + 10]),
                       payload: Array(raw[(i + 11)..<(i + len - 2)]), start: i, length: len))
            i += len
        }
    }

    /// First reply frame with the given cmdset/cmd across `datagrams`, skipping the empty transport
    /// ACK the camera sends before the real reply.
    public static func findReply(_ datagrams: [[UInt8]], set: Int, cmd: Int) -> [UInt8]? {
        for d in datagrams {
            var found: [UInt8]?
            walk(d) { f in
                if found == nil, f.cmdSet == set, f.cmdId == cmd, !f.payload.isEmpty { found = f.payload }
            }
            if let found { return found }
        }
        return nil
    }
}

/// Accumulates BLE notification bytes and yields complete, CRC-valid DUML messages. Handles several
/// frames in one notification and a frame split across two.
public struct DumlFrameAccumulator: Sendable {
    private var buffer: [UInt8] = []

    public init() {}

    public mutating func append(_ bytes: [UInt8]) -> [DjiMessage] {
        buffer += bytes
        var out: [DjiMessage] = []
        var i = 0
        var consumed = 0
        while i + 4 <= buffer.count {
            guard buffer[i] == 0x55 else { i += 1; continue }
            let len = (Int(buffer[i + 1]) | (Int(buffer[i + 2]) << 8)) & 0x3FF
            guard len >= 13, DjiCrc.crc8(buffer[i..<(i + 3)]) == buffer[i + 3] else { i += 1; continue }
            if i + len > buffer.count { break }          // header is sound, body still arriving
            if let m = DjiMessage(frame: Array(buffer[i..<(i + len)])) {
                out.append(m)
                i += len
                consumed = i
            } else {
                i += 1
            }
        }
        // Keep only what could still be the start of a frame; cap the tail so noise can't grow it.
        let keepFrom = Swift.max(consumed, i)
        buffer = keepFrom < buffer.count ? Array(buffer[keepFrom...]) : []
        if buffer.count > 2048 { buffer.removeAll() }
        return out
    }
}
