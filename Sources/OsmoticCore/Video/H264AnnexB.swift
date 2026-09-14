import Foundation

/// Minimal H.264 Annex-B handling for the live view: split a byte stream on start codes and name the
/// NAL units that matter for decoding.
public enum H264AnnexB {
    public enum NALType: UInt8 {
        case slice = 1
        case idr = 5
        case sei = 6
        case sps = 7
        case pps = 8
        case aud = 9
    }

    /// NAL unit type of a unit without its start code.
    public static func type(of nal: [UInt8]) -> UInt8 { nal.first.map { $0 & 0x1F } ?? 0 }

    /// The NAL units in `data`, start codes (`00 00 01` or `00 00 00 01`) removed. Bytes before the
    /// first start code are dropped; empty units are skipped.
    public static func units(_ data: [UInt8]) -> [[UInt8]] {
        var starts: [(at: Int, len: Int)] = []
        var i = 0
        let n = data.count
        while i + 2 < n {
            if data[i] == 0, data[i + 1] == 0 {
                if data[i + 2] == 1 { starts.append((i, 3)); i += 3; continue }
                if i + 3 < n, data[i + 2] == 0, data[i + 3] == 1 { starts.append((i, 4)); i += 4; continue }
            }
            i += 1
        }
        var out: [[UInt8]] = []
        for (k, s) in starts.enumerated() {
            let begin = s.at + s.len
            let end = k + 1 < starts.count ? starts[k + 1].at : n
            if end > begin { out.append(Array(data[begin..<end])) }
        }
        return out
    }

    /// AVCC framing (4-byte big-endian length before each unit), as `CMSampleBuffer` wants it.
    public static func avcc(_ units: [[UInt8]]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(units.reduce(0) { $0 + $1.count + 4 })
        for u in units {
            let l = UInt32(u.count)
            out += [UInt8(l >> 24), UInt8((l >> 16) & 0xFF), UInt8((l >> 8) & 0xFF), UInt8(l & 0xFF)]
            out += u
        }
        return out
    }
}
