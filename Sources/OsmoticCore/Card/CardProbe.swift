import Foundation

/// How fast the card actually reads, measured instead of assumed. The cable, the hub and the card
/// all cap the rate, and the bus's headline number ("480 Mb/s") says little about what a 40 GB card
/// will take: this reads a stretch of a real clip for about a second and reports MB/s.
///
/// It only ever reads, and never the whole file: a fixed slice, discarded as it arrives.
public enum CardProbe: Sendable {
    /// Read in 4 MiB blocks, as the copier does, so the number means the same thing.
    static let block = 4 << 20

    /// Measures for `seconds` (about a second is enough to tell USB 2 from USB 3) and returns MB/s,
    /// or nil when there is nothing big enough to measure on.
    public static func readSpeed(on volume: URL, seconds: Double = 1.1) -> Double? {
        guard let sample = biggestFile(on: volume) else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: sample) else { return nil }
        defer { try? handle.close() }

        // The first block warms the path up (spin-up, caches, USB negotiation) and is not counted.
        guard let first = try? handle.read(upToCount: block), !first.isEmpty else { return nil }
        let started = Date()
        var read = 0
        while Date().timeIntervalSince(started) < seconds {
            guard let chunk = try? handle.read(upToCount: block), !chunk.isEmpty else { break }
            read += chunk.count
        }
        // A small file can run out before the clock does; what was read still tells the rate.
        let elapsed = Date().timeIntervalSince(started)
        guard read >= block, elapsed > 0.002 else { return nil }
        return Double(read) / elapsed / 1_000_000
    }

    /// The largest clip on the card: the one that says most about a long copy.
    static func biggestFile(on volume: URL) -> URL? {
        let files = CardScanner.files(on: volume)
        guard let biggest = files.max(by: { $0.sizeBytes < $1.sizeBytes }), biggest.sizeBytes > block * 2 else {
            return nil
        }
        return CardScanner.url(for: biggest.path, on: volume)
    }

    /// How long `bytes` take at `mbPerSecond`, for "about 20 minutes" next to a card's size.
    public static func minutes(forBytes bytes: Int, at mbPerSecond: Double) -> Int? {
        guard bytes > 0, mbPerSecond > 0.5 else { return nil }
        return max(1, Int((Double(bytes) / 1_000_000 / mbPerSecond / 60).rounded()))
    }
}
