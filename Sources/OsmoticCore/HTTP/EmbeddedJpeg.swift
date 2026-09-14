import Foundation

/// Lift the thumbnail a camera embeds in a JPEG's EXIF `APP1` block — used when a still has no
/// `.thm`/`.scr` rendition. Structural: the search is confined to `APP1` and stops at `SOS`.
public enum EmbeddedJpeg {
    /// EXIF's `APP1` length is a u16, so the first 64 KiB always contain it.
    public static let headBytes = 65_536

    public static func fromHeader(_ head: [UInt8]) -> [UInt8]? {
        guard head.count >= 4, head[0] == 0xFF, head[1] == 0xD8 else { return nil }
        var i = 2
        while i + 4 <= head.count {
            if head[i] != 0xFF { i += 1; continue }
            let marker = head[i + 1]
            switch marker {
            case 0xD8, 0x01, 0xD0...0xD7:
                i += 2
            case 0xDA, 0xD9:
                return nil
            default:
                let len = (Int(head[i + 2]) << 8) | Int(head[i + 3])
                if len < 2 { return nil }
                if marker == 0xE1, let jpeg = jpegWithin(head, from: i + 4, to: min(i + 2 + len, head.count)) {
                    return jpeg
                }
                i += 2 + len
            }
        }
        return nil
    }

    private static func jpegWithin(_ b: [UInt8], from: Int, to: Int) -> [UInt8]? {
        var soi = -1
        var i = from
        while i < to - 1 {
            if b[i] == 0xFF && b[i + 1] == 0xD8 { soi = i; break }
            i += 1
        }
        guard soi >= 0 else { return nil }
        var j = to - 2
        while j > soi {
            if b[j] == 0xFF && b[j + 1] == 0xD9 { return Array(b[soi..<(j + 2)]) }
            j -= 1
        }
        return nil
    }
}
