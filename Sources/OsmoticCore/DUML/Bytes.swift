import Foundation

/// Little-endian readers and small builders over `[UInt8]`, the byte type the whole protocol layer
/// speaks. Every read is bounds-checked by the caller; these helpers assume the range is valid.
extension Array where Element == UInt8 {
    /// Build from a hex string, ignoring whitespace. `"4a 00 21 10"` → `[0x4a, 0x00, 0x21, 0x10]`.
    public init(hex: String) {
        let clean = hex.filter { !$0.isWhitespace }
        var out: [UInt8] = []
        out.reserveCapacity(clean.count / 2)
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2, limitedBy: clean.endIndex) ?? clean.endIndex
            out.append(UInt8(clean[index..<next], radix: 16) ?? 0)
            index = next
        }
        self = out
    }

    public var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    @inline(__always) func u8(_ i: Int) -> Int { Int(self[i]) }

    @inline(__always) func u16le(_ i: Int) -> Int {
        Int(self[i]) | (Int(self[i + 1]) << 8)
    }

    @inline(__always) func u32le(_ i: Int) -> Int {
        Int(self[i]) | (Int(self[i + 1]) << 8) | (Int(self[i + 2]) << 16) | (Int(self[i + 3]) << 24)
    }

    @inline(__always) func i32le(_ i: Int) -> Int {
        Int(Int32(bitPattern: UInt32(truncatingIfNeeded: u32le(i))))
    }

    /// Index of the first occurrence of `needle`, or nil.
    func firstIndex(of needle: [UInt8], from start: Int = 0) -> Int? {
        guard !needle.isEmpty, count >= needle.count else { return nil }
        var i = Swift.max(0, start)
        let last = count - needle.count
        let first = needle[0]
        while i <= last {
            if self[i] == first {
                var j = 1
                while j < needle.count && self[i + j] == needle[j] { j += 1 }
                if j == needle.count { return i }
            }
            i += 1
        }
        return nil
    }

    /// ISO-8859-1 decode of a byte range — every byte maps to one character, so lengths agree.
    func latin1(_ start: Int, _ length: Int) -> String {
        String(decoding: self[start..<(start + length)].map { UInt16($0) }, as: UTF16.self)
    }
}

public enum LE {
    public static func u16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    public static func u24(_ v: Int) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF)]
    }
    public static func u32(_ v: Int) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }
    public static func u64(_ v: Int) -> [UInt8] {
        (0..<8).map { UInt8((v >> ($0 * 8)) & 0xFF) }
    }
}
