import Foundation
import Testing

@testable import OsmoticCore

/// Everything that parses bytes from the camera (an untrusted network peer) must survive garbage:
/// random bytes, and real frames with random corruption. The tests pass if nothing traps.
@Suite struct FuzzTests {
    /// Deterministic PRNG so a failure reproduces.
    struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static func blobs(count: Int, seed: UInt64, maxLength: Int = 4096) -> [[UInt8]] {
        var rng = SplitMix(state: seed)
        return (0..<count).map { _ in
            let n = Int.random(in: 0...maxLength, using: &rng)
            var b = (0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) }
            // Sprinkle frame-start bytes so the scanners take their deeper paths.
            for i in stride(from: 0, to: b.count, by: 97) { b[i] = 0x55 }
            return b
        }
    }

    /// Real manifest bytes with random bit flips.
    static func corrupted(_ base: [UInt8], count: Int, seed: UInt64) -> [[UInt8]] {
        var rng = SplitMix(state: seed)
        return (0..<count).map { _ in
            var b = base
            for _ in 0..<Int.random(in: 1...40, using: &rng) where !b.isEmpty {
                b[Int.random(in: 0..<b.count, using: &rng)] ^= UInt8.random(in: 1...255, using: &rng)
            }
            if Bool.random(using: &rng) { b = Array(b.prefix(Int.random(in: 0...b.count, using: &rng))) }
            return b
        }
    }

    @Test func `the manifest decoder survives random and corrupted input`() throws {
        let real = try fixture("op3_29.bin")
        for b in Self.blobs(count: 300, seed: 1) + Self.corrupted(real, count: 300, seed: 2) {
            _ = ManifestDecoder.decodeBlob(b)
            _ = ManifestDecoder.collectStores(b, log: { _ in })
            _ = ManifestDecoder.countMediaPaths(ManifestDecoder.manifestBytes(b))
        }
    }

    @Test func `frame scanners and the BLE accumulator survive garbage`() {
        var acc = DumlFrameAccumulator()
        for b in Self.blobs(count: 500, seed: 3, maxLength: 2048) {
            DumlScanner.walk(b) { _ in }
            _ = DumlScanner.findReply([b], set: 0x02, cmd: 0x80)
            _ = acc.append(b)
        }
    }

    @Test func `status parsing survives garbage`() {
        var tracker = StatusTracker()
        for b in Self.blobs(count: 500, seed: 4, maxLength: 512) {
            _ = tracker.ingest([b], log: { _ in })
            for (set, id) in [(0x02, 0x80), (0x02, 0xDC), (0x0D, 0x02), (0x00, 0x00)] {
                tracker.apply(set: set, id: id, payload: b, log: { _ in })
            }
        }
    }

    @Test func `the live reassembler survives garbage`() {
        var r = LiveReassembler()
        var t = 0.0
        for b in Self.blobs(count: 800, seed: 5, maxLength: 1500) {
            t += 0.01
            _ = r.feed(b, now: t)
            _ = H264AnnexB.units(b)
        }
    }

    @Test func `embedded JPEG extraction survives garbage`() {
        for b in Self.blobs(count: 400, seed: 6, maxLength: 8192) {
            _ = EmbeddedJpeg.fromHeader(b)
        }
    }
}
