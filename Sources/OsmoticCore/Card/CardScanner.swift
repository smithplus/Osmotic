import Foundation

/// The camera's card, read straight off a mounted volume. Plugged in over USB-C in storage mode, an
/// Osmo shows up as a removable disk with `DCIM/DJI_xxx` on it: no Bluetooth, no Wi-Fi, no datalink,
/// and the sizes are the file system's, so nothing wraps above 4 GiB.
///
/// The card is still untrusted input: every name goes through `CameraFile.safeFileName` before it is
/// used on the Mac, and only files inside the volume's own `DCIM` are ever read.
public enum CardScanner {
    /// Files the app lists, the ones people came for. Sidecars (`.LRF`, `.WAV`) hang off these.
    public static let mainExts: Set<String> = ["MP4", "MOV", "JPG", "JPEG", "DNG", "HEIC", "OSV", "INSV"]
    /// Companions the camera writes next to a clip.
    public static let sidecarExts: Set<String> = ["LRF", "LRV", "WAV", "XRF", "DNG"]

    /// What a look at a volume found.
    public enum Access: Equatable, Sendable {
        /// A `DCIM` with folders in it: a camera's card.
        case card
        /// Readable, but nothing a camera wrote.
        case notACard
        /// macOS refuses the read: on Ventura and later, files on removable volumes are behind a
        /// permission the app has to be granted (Privacy & Security › Files and Folders).
        case denied
    }

    /// Looks at one volume, saying apart "not a card" from "not allowed to look".
    public static func access(to volume: URL) -> Access {
        let dcim = volume.appendingPathComponent("DCIM", isDirectory: true)
        do {
            let items = try FileManager.default.contentsOfDirectory(
                at: dcim, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            let hasFolder = items.contains { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            return hasFolder ? .card : .notACard
        } catch let error as NSError {
            let denied =
                error.code == NSFileReadNoPermissionError
                || (error.domain == NSPOSIXErrorDomain && error.code == Int(EPERM))
                || (error.underlyingErrors.first as? NSError)?.code == Int(EPERM)
            return denied ? .denied : .notACard
        }
    }

    /// True when the volume looks like a camera's card: it has a `DCIM` with at least one folder in it.
    public static func isCameraCard(_ volume: URL) -> Bool { access(to: volume) == .card }

    /// What the card holds, newest first, as the same `CameraFile` the wireless path produces: `path`
    /// is relative to the volume (`DCIM/DJI_001/DJI_….MP4`), `sizeBytes` is the real size on disk and
    /// `proxyPath` points at the `.LRF` next to a clip when the camera wrote one.
    public static func files(on volume: URL) -> [CameraFile] {
        let dcim = volume.appendingPathComponent("DCIM", isDirectory: true)
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard
            let walker = FileManager.default.enumerator(
                at: dcim, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }

        var mains: [CameraFile] = []
        var sidecars: [String: [String: String]] = [:]  // stem → extension → relative path
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            let name = url.lastPathComponent
            guard name == CameraFile.safeFileName(name) else { continue }  // odd name: leave it alone
            let ext = (name as NSString).pathExtension.uppercased()
            let relative = relativePath(of: url, in: volume)
            let stem = (name as NSString).deletingPathExtension
            if mainExts.contains(ext) {
                var f = CameraFile(
                    path: relative, thumbPath: "", sizeBytes: max(0, values?.fileSize ?? 0),
                    mediaType: mediaType(for: ext))
                f.storageKnown = true
                mains.append(f)
            } else if sidecarExts.contains(ext) {
                sidecars[stem, default: [:]][ext] = relative
            }
        }
        // A clip's proxy is the `.LRF` (or `.LRV`) written under the same name.
        for i in mains.indices {
            let stem = (mains[i].name as NSString).deletingPathExtension
            if let proxy = sidecars[stem]?["LRF"] ?? sidecars[stem]?["LRV"] { mains[i].proxyPath = proxy }
        }
        return mains.newestFirst()
    }

    /// The companions to copy beside `file` (the RAW `.DNG`, the backup `.WAV`, the proxy `.LRF`),
    /// as paths relative to the volume.
    public static func sidecars(of file: CameraFile, on volume: URL, includeProxy: Bool = false) -> [String] {
        let dir = (file.path as NSString).deletingLastPathComponent
        let stem = (file.name as NSString).deletingPathExtension
        var wanted = ["WAV"]
        if file.ext == "JPG" || file.ext == "JPEG" { wanted.append("DNG") }
        if includeProxy { wanted.append(contentsOf: ["LRF", "LRV"]) }
        return wanted.compactMap { ext in
            let relative = dir.isEmpty ? "\(stem).\(ext)" : "\(dir)/\(stem).\(ext)"
            let url = volume.appendingPathComponent(relative)
            return FileManager.default.fileExists(atPath: url.path) ? relative : nil
        }
    }

    /// `volume` plus a path this scanner produced. Anything that isn't inside the volume's `DCIM`
    /// (a `..` slipped into a name, an absolute path) is refused.
    public static func url(for relativePath: String, on volume: URL) -> URL? {
        guard !relativePath.hasPrefix("/"), !relativePath.contains("..") else { return nil }
        let url = volume.appendingPathComponent(relativePath).standardizedFileURL
        let dcim = volume.appendingPathComponent("DCIM", isDirectory: true).standardizedFileURL
        guard url.path.hasPrefix(dcim.path + "/") else { return nil }
        return url
    }

    private static func relativePath(of url: URL, in volume: URL) -> String {
        let base = volume.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(base) else { return url.lastPathComponent }
        return String(path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// DJI's `MediaFileType`, as far as the extension tells: 0 JPEG, 1 DNG, 2 MOV, 3 MP4.
    private static func mediaType(for ext: String) -> Int {
        switch ext {
        case "JPG", "JPEG", "HEIC": 0
        case "DNG": 1
        case "MOV": 2
        case "MP4", "OSV", "INSV": 3
        default: -1
        }
    }
}
