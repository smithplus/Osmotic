import Foundation

/// Joins the camera's live-view fragments (pktType 0x02 datagrams) back into whole messages.
///
/// A message starts with a fragment whose payload (from byte 20 of the datagram) begins
/// `00 00 01 FF` + u32 LE length + 8 bytes of metadata; the H.264 Annex-B bytes follow, and later
/// fragments append from their byte 20 until the declared length is reached. A missing fragment
/// (transport seq not +8) or a stale partial drops the message rather than showing a corrupt one.
/// Adapted from Kaze for DJI (MIT), `Pocket3VideoOutput.consume`; continuity rule after OpenPocketCine.
public struct LiveReassembler: Sendable {
    public private(set) var dropped = 0
    public private(set) var invalid = 0
    private var buffer: [UInt8] = []
    private var expected: Int?
    private var lastSeq: Int?
    private var startedAt: TimeInterval = 0

    public static let maxMessage = 8 << 20
    public static let staleAfter: TimeInterval = 1.5

    public init() {}

    /// Feed one whole datagram; returns a completed message (Annex-B bytes) when this fragment ends one.
    public mutating func feed(_ d: [UInt8], now: TimeInterval) -> [UInt8]? {
        guard d.count > 20 else { return nil }
        let seq = d.u16le(4)
        let first = d.count >= 36 && d[20] == 0 && d[21] == 0 && d[22] == 1 && d[23] == 0xFF
        if first {
            if expected != nil { dropped += 1 }
            let length = d.u32le(24)
            guard length > 0, length <= Self.maxMessage else { invalid += 1; reset(); return nil }
            expected = length
            buffer.removeAll(keepingCapacity: true)
            buffer.reserveCapacity(length)
            buffer += d[36...]
            startedAt = now
        } else {
            guard expected != nil else { return nil }   // joined mid-message: wait for the next start
            if let last = lastSeq, seq == last { return nil }   // duplicate
            if let last = lastSeq, seq != (last + 8) & 0xFFFF { dropped += 1; reset(); return nil }
            if now - startedAt > Self.staleAfter { dropped += 1; reset(); return nil }
            buffer += d[20...]
        }
        lastSeq = seq
        guard let e = expected, buffer.count >= e else { return nil }
        let message = Array(buffer.prefix(e))
        reset()
        return message
    }

    public mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
        expected = nil
        lastSeq = nil
    }
}
