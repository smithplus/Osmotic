import Foundation
import ImageIO

/// Fetches grid thumbnails with bounded concurrency and a disk cache.
///
/// A clip's `.scr` screennail is tried first; stills carry a `.thm` instead, and as a last resort the
/// JPEG's own EXIF thumbnail is lifted out of its first 64 KiB.
public actor ThumbnailFetcher {
    private let http: CameraHTTP
    private let cacheDir: URL
    private let maxConcurrent: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(http: CameraHTTP, cacheDir: URL, maxConcurrent: Int = 4) {
        self.http = http
        self.cacheDir = cacheDir
        self.maxConcurrent = maxConcurrent
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    /// The disk-cache key: the path plus size, so a reused file number never shows a stale image.
    nonisolated func cacheURL(for file: CameraFile) -> URL {
        let key = "\(file.path)|\(file.sizeBytes)"
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in key.utf8 { hash = (hash ^ UInt64(b)) &* 0x0000_0100_0000_01b3 }
        return cacheDir.appendingPathComponent(String(hash, radix: 16) + ".img")
    }

    /// Cached bytes without touching the network.
    public nonisolated func cached(_ file: CameraFile) -> Data? {
        try? Data(contentsOf: cacheURL(for: file))
    }

    /// Grid thumbnails are drawn at most ~280 pt wide: 560 px covers Retina. A camera screennail is
    /// 1280×720 (~460 KB, ~2.7 MB decoded); the downsampled JPEG is ~40 KB.
    public static let maxPixel = 560

    public func thumbnail(for file: CameraFile) async -> Data? {
        if let hit = cached(file) {
            // Caches written before downsampling: shrink once, in place.
            guard hit.count > 150_000, let small = Self.downsample(hit) else { return hit }
            try? small.write(to: cacheURL(for: file), options: .atomic)
            return small
        }
        await acquire()
        defer { release() }
        if Task.isCancelled { return nil }
        var data = await http.data(file.thumbURLPath)
        if data == nil && file.thumbPath.hasSuffix(".scr") {
            let thm = String(file.thumbPath.dropLast(4)) + ".thm"
            data = await http.data(CameraFile.urlPath(storage: file.storage, path: thm))
        }
        if data == nil && file.isImage {
            if let head = await http.range(file.originalURLPath, from: 0, to: EmbeddedJpeg.headBytes - 1),
                let jpeg = EmbeddedJpeg.fromHeader([UInt8](head))
            {
                data = Data(jpeg)
            }
        }
        // Cache only real images: anything else (an error page from some other device) would stick.
        guard let data, Self.looksLikeImage(data) else { return data }
        let small = Self.downsample(data) ?? data
        try? small.write(to: cacheURL(for: file), options: .atomic)
        return small
    }

    /// A JPEG no wider or taller than `maxPixel`, or nil if the bytes aren't an image ImageIO reads.
    static func downsample(_ data: Data, maxPixel: Int = maxPixel) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    static func looksLikeImage(_ data: Data) -> Bool {
        data.starts(with: [0xFF, 0xD8]) || data.starts(with: [0x89, 0x50, 0x4E, 0x47])
    }

    private func acquire() async {
        if running < maxConcurrent { running += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { running -= 1 } else { waiters.removeFirst().resume() }
    }
}
