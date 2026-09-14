import Foundation

/// What one store's answer to a page query looked like on the wire.
public struct SliceInfo: Sendable, Equatable {
    /// The manifest's own `u32-LE` record count (0 on bodies that write none).
    public let declared: Int
    /// Media-path fields actually present.
    public let records: Int
    /// The camera's `0c 01` "nothing older" marker.
    public let endMarker: Bool
    /// A `4A 03` end frame arrived for this store's counter.
    public let ended: Bool

    /// Fewer records than declared: truncated in transit, not a short page.
    public var incomplete: Bool { declared >= 1 && declared <= ManifestDecoder.countMax && records < declared }
}

/// One cursor per store: a page request is a pair of queries, counter 1 selecting the SD card and
/// counter 2 the internal store (the cursor's `0x40000000` bit is the store selector).
public struct Pagination: Sendable {
    public static let sdStore = 0
    public static let internalStore = 1
    public static let newestSd = 0x0000_0001
    public static let newestInternal = 0x4000_0001
    public static let sdQueryCtr = 1
    public static let internalQueryCtr = 2
    public static let pageSize = 45
    public static let trigger: [UInt8] = [UInt8](hex: "4a040e1001000000000001000000")

    public var sdCursor = newestSd
    public var internalCursor = newestInternal
    public var moreAvailable = false
    private var seen = Set<String>()

    public init() {}

    /// A `0x00/0x26` list query for request counter `ctr` at `cursor`.
    public static func listCommand(ctr: Int, cursor: Int, pageSize: Int = pageSize) -> [UInt8] {
        var p = [UInt8](hex: "4a002a10010000000000010000002d000d0100ffffffffffffffff000100000000000000000000000000")
        p[4] = UInt8(ctr & 0xFF)
        p[14] = UInt8(pageSize & 0xFF)
        p[10] = UInt8(cursor & 0xFF)
        p[11] = UInt8((cursor >> 8) & 0xFF)
        p[12] = UInt8((cursor >> 16) & 0xFF)
        p[13] = UInt8((cursor >> 24) & 0xFF)
        return p
    }

    /// Which store a record pages under: the query that returned it, else its handle's store bit.
    public static func storeOf(_ f: CameraFile) -> Int {
        if f.storageKnown { return f.storage }
        let h = f.handle != 0 ? f.handle : f.cmdHandle
        if h != 0 { return (h & 0x4000_0000) != 0 ? 1 : 0 }
        return f.group
    }

    static func slice(_ page: [CameraFile], _ store: Int) -> [CameraFile] { page.filter { storeOf($0) == store } }

    static func oldestHandle(_ page: [CameraFile], store: Int, below: Int) -> Int? {
        slice(page, store).map(\.handle).filter { $0 != 0 && $0 < below }.min()
    }

    static func key(_ f: CameraFile) -> String { "\(storeOf(f)):\(f.path)" }

    /// Does a store's slice leave an older page to fetch?
    public static func storeHasOlderPage(sliceSize: Int, cursorMoved: Bool, info: SliceInfo?) -> Bool {
        guard cursorMoved else { return false }
        guard let info else { return sliceSize >= pageSize }
        if info.incomplete { return true }
        if info.endMarker { return false }
        return sliceSize >= pageSize
    }

    /// Seed from the newest page.
    public mutating func seed(with files: [CameraFile], slices: [Int: SliceInfo]) {
        seen = Set(files.map(Self.key))
        let sdOldest = Self.oldestHandle(files, store: Self.sdStore, below: .max)
        let intOldest = Self.oldestHandle(files, store: Self.internalStore, below: .max)
        sdCursor = sdOldest ?? Self.newestSd
        internalCursor = intOldest ?? Self.newestInternal
        moreAvailable =
            Self.storeHasOlderPage(
                sliceSize: Self.slice(files, Self.sdStore).count, cursorMoved: sdOldest != nil, info: slices[Self.sdStore])
            || Self.storeHasOlderPage(
                sliceSize: Self.slice(files, Self.internalStore).count, cursorMoved: intOldest != nil,
                info: slices[Self.internalStore])
    }

    /// Advance both cursors past a freshly decoded page; returns only the files not seen before.
    public mutating func step(page: [CameraFile], slices: [Int: SliceInfo]) -> [CameraFile] {
        let fresh = page.filter { seen.insert(Self.key($0)).inserted }
        let sdOldest = Self.oldestHandle(page, store: Self.sdStore, below: sdCursor)
        let intOldest = Self.oldestHandle(page, store: Self.internalStore, below: internalCursor)
        moreAvailable =
            !fresh.isEmpty
            && (Self.storeHasOlderPage(
                sliceSize: Self.slice(page, Self.sdStore).count, cursorMoved: sdOldest != nil, info: slices[Self.sdStore])
                || Self.storeHasOlderPage(
                    sliceSize: Self.slice(page, Self.internalStore).count, cursorMoved: intOldest != nil,
                    info: slices[Self.internalStore]))
        sdCursor = sdOldest ?? sdCursor
        internalCursor = intOldest ?? internalCursor
        return fresh
    }

    public var cursorDescription: String { String(format: "sd=0x%08x int=0x%08x", sdCursor, internalCursor) }
}

extension ManifestDecoder {
    /// Split one collected blob into its per-store answers by the request counter each chunk echoes,
    /// so every file's `/v2?storage=` mount is known from the query that returned it.
    public static func collectStores(_ raw: [UInt8], log: Log) -> (files: [CameraFile], slices: [Int: SliceInfo]) {
        let tally = chunkTally(raw)
        var slices: [Int: SliceInfo] = [:]
        func sliceOf(_ ctr: Int) -> [CameraFile] {
            let storeName = ctr == Pagination.sdQueryCtr ? "SD" : "internal"
            let bytes = manifestBytes(raw, requestCtr: ctr)
            let files = bytes.isEmpty ? [] : decode(bytes, store: storeName, log: log)
            let info = SliceInfo(
                declared: bytes.count >= 4 ? bytes.u32le(0) : -1,
                records: countMediaPaths(bytes),
                endMarker: hasEndMarker(bytes),
                ended: (tally[ctr]?[0x03] ?? 0) > 0)
            slices[ctr == Pagination.sdQueryCtr ? Pagination.sdStore : Pagination.internalStore] = info
            if info.incomplete {
                log(
                    "datalink: \(storeName) slice TRUNCATED — header declares \(info.declared) records, "
                        + "\(info.records) arrived (end frame \(info.ended ? "seen" : "missing"))")
            }
            return files
        }
        let sd = sliceOf(Pagination.sdQueryCtr)
        let internalFiles = sliceOf(Pagination.internalQueryCtr)
        if sd.isEmpty { log("datalink: SD slice empty — reply frames by request counter: \(chunkCensus(raw))") }
        let ambiguous = !sd.isEmpty && !internalFiles.isEmpty && Set(sd.map(\.path)) == Set(internalFiles.map(\.path))
        if (sd.isEmpty && internalFiles.isEmpty) || ambiguous {
            let merged = decode(manifestBytes(raw), log: log)
            log(
                "datalink: store split unavailable (\(ambiguous ? "both queries same list" : "no counter echo")) — "
                    + "\(merged.count) files, storage resolved per file")
            return (inferMissingExtensions(merged, log: log), slices)
        }
        log("datalink: per-store lists — SD \(sd.count), internal \(internalFiles.count)")
        var out: [CameraFile] = []
        var paths = Set<String>()
        for var f in internalFiles { f.storage = 1; f.storageKnown = true; if paths.insert(f.path).inserted { out.append(f) } }
        for var f in sd { f.storage = 0; f.storageKnown = true; if paths.insert(f.path).inserted { out.append(f) } }
        return (inferMissingExtensions(out, log: log), slices)
    }
}
