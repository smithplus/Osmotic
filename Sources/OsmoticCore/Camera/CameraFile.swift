import Foundation

/// One media item on the camera, as decoded from the CompositePack manifest.
public struct CameraFile: Sendable, Hashable, Identifiable {
    /// e.g. `DCIM/DJI_001/DJI_20260329115359_0211_D.MP4`
    public var path: String
    /// e.g. `MISC/THM/DJI_001/DJI_20260329115359_0211_D.scr`
    public var thumbPath: String
    /// The `/v2?storage=N` mount serving this file.
    public var storage: Int = 0
    /// e.g. "25fps".
    public var resLabel: String?
    /// Low-res proxy clip (`.LRF`) when the manifest lists one.
    public var proxyPath: String?
    /// Camera-assigned handle read at the record's marker; 0 = unknown.
    public var handle: Int = 0
    public var sizeBytes: Int = 0
    public var starred = false
    /// "3840x2160"; nil = unknown.
    public var resolution: String?
    public var durationSec = 0
    /// Handle for non-destructive commands, fitted as `base + seq*step` per store list.
    public var cmdHandle: Int = 0
    /// Which per-store list of a merged manifest this record came from.
    public var group = 0
    /// True when `storage` came from the store-specific query that returned the record.
    public var storageKnown = false
    /// Another record in the same manifest carries this handle.
    public var handleShared = false
    /// DJI `MediaFileType` (0 JPEG, 1 DNG, 2 MOV, 3 MP4, 4 PANORAMA…), or -1.
    public var mediaType = -1
    /// The handle at the record's fixed position, before the fit vouches for it.
    public var handleCandidate: Int = 0

    public init(path: String, thumbPath: String, storage: Int = 0, resLabel: String? = nil,
                proxyPath: String? = nil, handle: Int = 0, sizeBytes: Int = 0, starred: Bool = false,
                resolution: String? = nil, durationSec: Int = 0, mediaType: Int = -1,
                handleCandidate: Int = 0) {
        self.path = path
        self.thumbPath = thumbPath
        self.storage = storage
        self.resLabel = resLabel
        self.proxyPath = proxyPath
        self.handle = handle
        self.sizeBytes = sizeBytes
        self.starred = starred
        self.resolution = resolution
        self.durationSec = durationSec
        self.mediaType = mediaType
        self.handleCandidate = handleCandidate
    }

    public var id: String { "\(storage):\(path)" }

    public var name: String { path.split(separator: "/").last.map(String.init) ?? path }

    /// The name the file is stored under on the Mac. The camera's name is untrusted network input, so
    /// only a plain, visible file name survives: see `safeFileName`.
    public var localName: String { Self.safeFileName(name) }

    /// Reduce `raw` to a plain file name that can only ever land inside the folder it is appended to:
    /// ASCII letters, digits, `-`, `_`, `.` and spaces; no leading dot (so never `.`, `..` or a hidden
    /// file); never empty; at most 200 characters. Real camera names (`DJI_20260804154141_0728_D.MP4`)
    /// pass through unchanged.
    public static func safeFileName(_ raw: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_. ")
        var s = String(raw.map { allowed.contains($0) ? $0 : "_" })
        while s.first == "." || s.first == " " { s.removeFirst() }
        while s.last == " " { s.removeLast() }
        if s.isEmpty { s = "file" }
        return String(s.prefix(200))
    }

    public var ext: String {
        guard let dot = name.lastIndex(of: ".") else { return "" }
        return String(name[name.index(after: dot)...]).uppercased()
    }

    /// The 14-digit `YYYYMMDDhhmmss` stamp in the name, or "".
    public var timestamp: String {
        name.firstMatch(of: /_(\d{14})_/).map { String($0.1) } ?? ""
    }

    public var seq: Int {
        name.firstMatch(of: /_(\d{4})_D/).flatMap { Int($0.1) } ?? 0
    }

    /// Capture date from the filename stamp (camera local time).
    public var captureDate: Date? {
        let t = timestamp
        guard t.count == 14 else { return nil }
        var c = DateComponents()
        func part(_ a: Int, _ b: Int) -> Int? {
            let s = t.index(t.startIndex, offsetBy: a), e = t.index(t.startIndex, offsetBy: b)
            return Int(t[s..<e])
        }
        c.year = part(0, 4); c.month = part(4, 6); c.day = part(6, 8)
        c.hour = part(8, 10); c.minute = part(10, 12); c.second = part(12, 14)
        return Calendar.current.date(from: c)
    }

    public static let videoExts: Set<String> = ["MP4", "MOV", "OSV", "INSV", "LRF", "LRV", "XRF"]
    public static let imageExts: Set<String> = ["JPG", "JPEG", "DNG", "HEIC", "RAW"]

    public var isVideo: Bool { Self.videoExts.contains(ext) }
    public var isImage: Bool { Self.imageExts.contains(ext) }
    public var isPanorama: Bool { mediaType == 4 }

    /// `_NNN` burst/interval sub-index, or 0.
    public var subIndex: Int {
        name.firstMatch(of: /_(\d{3})\.\w+$/).flatMap { Int($0.1) } ?? 0
    }

    public var isBurst: Bool { name.firstMatch(of: /^(.+)_\d{3}\.\w+$/) != nil }

    public var opHandle: Int { handle }
    public var deletable: Bool { opHandle != 0 && !handleShared }

    // ---- HTTP addressing (`/v2?storage=N&path=…`) ----------------------------------------------

    public static func urlPath(storage: Int, path: String) -> String {
        "/v2?storage=\(storage)&path=\(path)"
    }

    public var originalURLPath: String { Self.urlPath(storage: storage, path: path) }
    public var thumbURLPath: String { Self.urlPath(storage: storage, path: thumbPath) }

    /// Preview candidates, cheapest first: listed proxy, derived proxy for the family, then original.
    public var previewURLPaths: [String] {
        var urls: [String] = []
        func add(_ s: String) { if !urls.contains(s) { urls.append(s) } }
        if let proxyPath { add(Self.urlPath(storage: storage, path: proxyPath)) }
        let base = path.lastIndex(of: ".").map { String(path[..<$0]) } ?? path
        if name.hasPrefix("CAM_") { add(Self.urlPath(storage: storage, path: base + ".XRF")) }
        if name.hasPrefix("DJI_") { add(Self.urlPath(storage: storage, path: base + ".LRF")) }
        add(originalURLPath)
        return urls
    }

    /// The unlisted companion that might sit beside this file: `.DNG` for a JPEG, `.WAV` for a clip.
    public func sidecarCandidate() -> CameraFile? {
        let kind: String
        switch ext {
        case "JPG", "JPEG": kind = "DNG"
        case "MP4", "MOV": kind = "WAV"
        default: return nil
        }
        var c = self
        let base = path.lastIndex(of: ".").map { String(path[..<$0]) } ?? path
        c.path = base + "." + kind
        c.handle = 0; c.handleShared = false; c.handleCandidate = 0; c.sizeBytes = 0
        return c
    }
}

/// Live status decoded off the datalink pushes.
public struct CameraStatus: Sendable, Equatable {
    public var batteryPercent = -1
    public var storageFreeMb = -1
    public var storageTotalMb = -1
    public var sdTotalMb = -1
    public var sdFreeMb = -1
    public var internalTotalMb = -1
    public var internalFreeMb = -1
    public var firmware: String?
    public var batteryMilliVolts = -1
    public var batteryMilliAmps = 0
    public var docked = false
    public var charging = false
    /// Capture state, from the `0x02/0x80` push while the camera is out of playback.
    public var recording = false
    /// Between states: the camera is starting or stopping a recording.
    public var recordingTransition = false
    public var recordingSeconds = 0
    public var captureMode: CaptureMode?

    public init() {}

    public var sdInserted: Bool { sdTotalMb > 0 }

    /// The best free/total pair to show: the card when there is one, else built-in, else the active store.
    public var displayStorage: (freeMb: Int, totalMb: Int)? {
        if sdTotalMb > 0 { return (sdFreeMb, sdTotalMb) }
        if internalTotalMb > 0 { return (internalFreeMb, internalTotalMb) }
        if storageTotalMb > 0 { return (storageFreeMb, storageTotalMb) }
        return nil
    }
}
