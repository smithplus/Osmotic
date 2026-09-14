import Foundation

/// Decoder for DJI's **CompositePack** media manifest — the answer to a `0x00/0x26` list query,
/// streamed back as `0x00/0x27` chunks.
///
/// A faithful port of Osmosis' `CameraSession` decoder (MIT), which is pinned against real captures
/// of every Osmo body. Every field is length-delimited and read tag → length → value; nothing is
/// matched against a filename pattern, so custom folder/file prefixes decode like stock ones.
public enum ManifestDecoder {
    public typealias Log = (String) -> Void

    static let videoExts: Set<String> = ["MP4", "MOV", "OSV", "INSV"]
    static let stillExts: Set<String> = ["JPG", "JPEG", "DNG", "HEIC"]
    static let proxyExtsListed: Set<String> = ["LRF", "LRV", "XRF"]
    static let primaryExts: Set<String> = ["MP4", "MOV", "JPG", "JPEG", "DNG", "OSV", "INSV", "HEIC"]
    static let proxyExts: Set<String> = ["LRF", "LRV"]

    /// Largest manifest offset-0 value still read as a page record count.
    static let countMax = 512

    /// The favourite signature a Pocket 3 / Action 4 / Xtra record carries once, after its path.
    static let starSignature: [UInt8] = [0x1b, 0x0a, 0x00, 0x00, 0x00, 0x02, 0x02, 0x01, 0x14, 0x02, 0x15, 0x03]

    // ---- reassembly -----------------------------------------------------------------------------

    /// Stitch the `0x00/0x27` data chunks out of a raw datagram blob, stripping each 10-byte
    /// `4A 01 …` sub-header. With `requestCtr`, keep only chunks answering that request counter.
    public static func manifestBytes(_ raw: [UInt8], requestCtr: Int? = nil) -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        while i + 13 <= raw.count {
            if raw[i] != 0x55 { i += 1; continue }
            let len = (Int(raw[i + 1]) | (Int(raw[i + 2]) << 8)) & 0x3FF
            if len < 13 || i + len > raw.count { i += 1; continue }
            let plStart = i + 11
            let plLen = len - 13
            let ctrOk: Bool
            if let requestCtr {
                ctrOk = plStart + 4 < raw.count && Int(raw[plStart + 4]) == requestCtr
            } else {
                ctrOk = true
            }
            if raw[i + 9] == 0x00, raw[i + 10] == 0x27, ctrOk, plLen > 10,
               raw[plStart] == 0x4A, raw[plStart + 1] == 0x01 {
                out.append(contentsOf: raw[(plStart + 10)..<(plStart + plLen)])
            }
            i += len
        }
        if requestCtr != nil { return out }
        // Only trust the reassembly when it carries at least as many intact paths as the raw blob.
        return (!out.isEmpty && countMediaPaths(out) >= countMediaPaths(raw)) ? out : raw
    }

    /// `0x00/0x27` reply frames by request counter, then by `4A` subtype (04 start, 01 data, 03 end).
    public static func chunkTally(_ raw: [UInt8]) -> [Int: [Int: Int]] {
        var tally: [Int: [Int: Int]] = [:]
        var i = 0
        while i + 13 <= raw.count {
            if raw[i] != 0x55 { i += 1; continue }
            let len = (Int(raw[i + 1]) | (Int(raw[i + 2]) << 8)) & 0x3FF
            if len < 13 || i + len > raw.count { i += 1; continue }
            let plStart = i + 11
            if raw[i + 9] == 0x00, raw[i + 10] == 0x27, len - 13 >= 10, raw[plStart] == 0x4A {
                let ctr = Int(raw[plStart + 4])
                let sub = Int(raw[plStart + 1])
                tally[ctr, default: [:]][sub, default: 0] += 1
            }
            i += len
        }
        return tally
    }

    public static func chunkCensus(_ raw: [UInt8]) -> String {
        let tally = chunkTally(raw)
        if tally.isEmpty { return "none" }
        func name(_ s: Int) -> String {
            switch s { case 0x04: "start"; case 0x01: "data"; case 0x03: "end"; default: "sub\(s)" }
        }
        return tally.keys.sorted().map { ctr in
            let subs = tally[ctr]!.keys.sorted().map { "\(name($0))=\(tally[ctr]![$0]!)" }.joined(separator: ",")
            return "ctr\(ctr)={\(subs)}"
        }.joined(separator: " ")
    }

    /// Has the camera closed every answer in `raw` (and each `required` counter)? A counter is closed
    /// by its `4A 03` end frame, or by opening with no data at all (an empty store).
    public static func streamsEnded(_ raw: [UInt8], required: [Int] = []) -> Bool {
        let tally = chunkTally(raw)
        guard tally.values.contains(where: { ($0[0x01] ?? 0) > 0 }) else { return false }
        func closed(_ ctr: Int) -> Bool {
            guard let subs = tally[ctr] else { return false }
            return (subs[0x03] ?? 0) > 0 || ((subs[0x04] ?? 0) > 0 && (subs[0x01] ?? 0) == 0)
        }
        return required.allSatisfy(closed) && tally.keys.allSatisfy(closed)
    }

    /// The `0c 01` end-of-list TLV right before the last record's `0d` name field.
    public static func hasEndMarker(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 3 else { return false }
        for i in 0..<(bytes.count - 2) where bytes[i] == 0x0C && bytes[i + 1] == 0x01 && bytes[i + 2] == 0x0D {
            return true
        }
        return false
    }

    // ---- fields ---------------------------------------------------------------------------------

    struct TlvField { let value: String; let end: Int }

    /// A path field `1a [total:u8] 00 00 00 [sub] <ascii>` at `i`, value `total-6` bytes, printable,
    /// starting with `prefix`.
    static func readPathField(_ b: [UInt8], _ i: Int, sub: UInt8, prefix: String) -> TlvField? {
        guard i + 6 <= b.count, b[i] == 0x1A, b[i + 2] == 0, b[i + 3] == 0, b[i + 4] == 0, b[i + 5] == sub else {
            return nil
        }
        let slen = Int(b[i + 1]) - 6
        guard slen >= prefix.utf8.count, i + 6 + slen <= b.count else { return nil }
        let start = i + 6
        for k in start..<(start + slen) where b[k] < 0x20 || b[k] > 0x7E { return nil }
        let s = b.latin1(start, slen)
        return s.hasPrefix(prefix) ? TlvField(value: s, end: start + slen) : nil
    }

    public static func countMediaPaths(_ bytes: [UInt8]) -> Int {
        var seen = Set<String>()
        var i = 0
        while i < bytes.count {
            if let f = readPathField(bytes, i, sub: 1, prefix: "DCIM/") { seen.insert(f.value); i = f.end } else { i += 1 }
        }
        return seen.count
    }

    // ---- decode ---------------------------------------------------------------------------------

    /// Decode a reassembled manifest; falls back to a flat scrape when no CompositePack record exists.
    public static func decode(_ bytes: [UInt8], store: String = "", log: Log = { _ in }) -> [CameraFile] {
        let comp = decodeComposite(bytes, store: store, log: log)
        if !comp.isEmpty {
            log("datalink: decoded \(comp.count) CompositePack records\(store.isEmpty ? "" : " [\(store)]") " +
                "(\(comp.filter { $0.resLabel != nil }.count) fps, \(comp.filter { $0.proxyPath != nil }.count) proxies, " +
                "\(comp.filter(\.starred).count) starred, \(comp.filter { $0.sizeBytes > 0 }.count) sized)")
            return flagHandleCollisions(comp, log: log)
        }
        log("datalink: no CompositePack records — falling back to flat scrape (\(bytes.count) B)")
        return parseFlat(bytes, log: log)
    }

    /// Some records carry no `0d` filename field (two stills on a captured Pocket 3 card), which leaves
    /// the path without an extension — a URL the camera cannot serve. The record's own `MediaFileType`
    /// byte says what it is, so borrow the extension from that. Applied after decoding, so the decoder
    /// itself stays byte-for-byte with the upstream golden snapshots.
    public static func inferMissingExtensions(_ files: [CameraFile], log: Log = { _ in }) -> [CameraFile] {
        files.map { f in
            guard f.ext.isEmpty else { return f }
            let ext: String
            switch f.mediaType {
            case 0, 4: ext = "JPG"
            case 1: ext = "DNG"
            case 2: ext = "MOV"
            case 3: ext = "MP4"
            default: return f
            }
            var g = f
            g.path = f.path + "." + ext
            log("datalink: \(f.name) had no filename field — extension \(ext) from media type \(f.mediaType)")
            return g
        }
    }

    /// The whole raw-blob → reassemble → decode pipeline (what the golden tests pin).
    public static func decodeBlob(_ raw: [UInt8], log: Log = { _ in }) -> [CameraFile] {
        decode(manifestBytes(raw), log: log)
    }

    static func flagHandleCollisions(_ files: [CameraFile], log: Log) -> [CameraFile] {
        var byHandle: [Int: Int] = [:]
        for f in files where f.handle != 0 { byHandle[f.handle, default: 0] += 1 }
        let shared = Set(byHandle.filter { $0.value > 1 }.keys)
        if shared.isEmpty { return files }
        for h in shared.sorted() {
            let names = files.filter { $0.handle == h }.map(\.name).joined(separator: ", ")
            log(String(format: "datalink: HANDLE COLLISION 0x%08x shared by %@", h, names))
        }
        return files.map { f in
            var f = f
            if shared.contains(f.handle) { f.handleShared = true }
            return f
        }
    }

    static func decodeComposite(_ bytes: [UInt8], store: String, log: Log) -> [CameraFile] {
        struct Media { let pos: Int; let end: Int; let path: String }
        var medias: [Media] = []
        var i = 0
        while i < bytes.count {
            if let f = readPathField(bytes, i, sub: 1, prefix: "DCIM/") {
                medias.append(Media(pos: i, end: f.end, path: f.value)); i = f.end
            } else {
                i += 1
            }
        }
        if medias.isEmpty { return [] }

        let boundary = listBoundary(bytes, records: medias.count)
        if boundary > 0 { log("datalink: 2 manifest lists (\(boundary) + \(medias.count - boundary) records)") }

        var order: [String] = []
        var byPath: [String: CameraFile] = [:]
        for k in medias.indices {
            let m = medias[k]
            if byPath[m.path] != nil { continue }
            let lo = k > 0 ? medias[k - 1].end : 0
            let hi = k + 1 < medias.count ? medias[k + 1].pos : bytes.count
            var f = resolveRecord(bytes, mediaDir: m.path, lo: lo, hi: hi, selfPos: m.pos, log: log)
            f.group = (boundary > 0 && k >= boundary) ? 1 : 0
            byPath[m.path] = f
            order.append(m.path)
        }
        return withCmdHandles(order.map { byPath[$0]! }, store: store, log: log)
    }

    static func listBoundary(_ bytes: [UInt8], records: Int) -> Int {
        guard bytes.count >= 4 else { return -1 }
        let declared = bytes.u32le(0)
        return (declared >= 1 && declared < records) ? declared : -1
    }

    /// Most frequent value, ties going to the value seen first (Kotlin `groupingBy.eachCount().maxBy`).
    static func mode(_ values: [Int]) -> Int? {
        var counts: [Int: Int] = [:]
        var firstSeen: [Int] = []
        for v in values {
            if counts[v] == nil { firstSeen.append(v) }
            counts[v, default: 0] += 1
        }
        var best: Int?
        var bestCount = 0
        for v in firstSeen where counts[v]! > bestCount { best = v; bestCount = counts[v]! }
        return best
    }

    /// Fit `handle = base + seq*step` per store list from the records that expose a handle, then give
    /// every record its `cmdHandle`; promote a fixed-position candidate only when the fit agrees, and
    /// revoke a scanned handle the fit contradicts.
    static func withCmdHandles(_ files: [CameraFile], store: String, log: Log) -> [CameraFile] {
        var fits: [Int: (base: Int, step: Int)] = [:]
        var groups: [Int] = []
        for f in files where !groups.contains(f.group) { groups.append(f.group) }
        for group in groups {
            var seenSeq = Set<Int>()
            var pts: [(seq: Int, handle: Int)] = []
            for f in files where f.group == group && f.handle != 0 && f.seq > 0 {
                if seenSeq.insert(f.seq).inserted { pts.append((f.seq, f.handle)) }
            }
            pts.sort { $0.seq < $1.seq }
            if pts.count < 2 { continue }
            var steps: [Int] = []
            for k in 0..<(pts.count - 1) {
                let a = pts[k], b = pts[k + 1]
                let s = (b.handle - a.handle) / (b.seq - a.seq)
                if s > 0 { steps.append(s) }
            }
            guard let step = mode(steps) else { continue }
            guard let base = mode(pts.map { $0.handle - $0.seq * step }) else { continue }
            fits[group] = (base, step)
            let label = store.isEmpty ? "list \(group)" : (group == 0 ? store : "\(store) list \(group)")
            log("datalink: handle fit (\(label)): base=0x\(String(base, radix: 16)) step=0x\(String(step, radix: 16))")
        }
        if fits.isEmpty { return files }
        var promoted = 0, revoked = 0
        let out = files.map { f -> CameraFile in
            guard let fit = fits[f.group], f.seq > 0 else { return f }
            let fitted = fit.base + f.seq * fit.step
            var f = f
            if f.handle == 0 && f.handleCandidate != 0 && f.handleCandidate == fitted {
                promoted += 1
                f.handle = f.handleCandidate
            } else if f.handle != 0 && f.handle != fitted {
                revoked += 1
                f.handle = 0
            }
            f.cmdHandle = fitted
            return f
        }
        if promoted > 0 { log("datalink: \(promoted) record(s) took their handle from the fixed marker (fit agrees)") }
        if revoked > 0 { log("datalink: \(revoked) handle(s) disagreed with the fit — not deletable") }
        return out
    }

    /// Build one record from its media-path field, searching the window `[lo, hi)` for its thumbnail,
    /// extension and the fixed fields hanging off the `[00|03] [ff|fe] 19 06` marker.
    static func resolveRecord(_ b: [UInt8], mediaDir: String, lo: Int, hi: Int, selfPos: Int, log: Log) -> CameraFile {
        let base = mediaDir.split(separator: "/").last.map(String.init) ?? mediaDir
        let baseLen = base.utf8.count

        var thumb: String?
        var t = lo
        while t < hi {
            if let f = readPathField(b, t, sub: 2, prefix: "MISC/"), f.value.hasSuffix(base) { thumb = f.value; break }
            t += 1
        }

        var ext = ""
        var proxyExt: String?
        var n = lo
        while n < hi - 2 {
            if b[n] == 0x0D {
                let len = Int(b[n + 1])
                if len > baseLen && n + 2 + len <= b.count {
                    let v = b.latin1(n + 2, len)
                    if v.utf8.count > baseLen + 1, v.hasPrefix(base),
                       v.utf8[v.utf8.index(v.utf8.startIndex, offsetBy: baseLen)] == UInt8(ascii: ".") {
                        let e = String(v.dropFirst(baseLen + 1)).uppercased()
                        if videoExts.contains(e) || stillExts.contains(e) { ext = e }
                        else if proxyExtsListed.contains(e) { proxyExt = e }
                    }
                }
            }
            n += 1
        }

        var head = -1
        let markerEnd = (selfPos >= lo + 1 && selfPos <= hi) ? selfPos : hi
        var m = lo
        while m < markerEnd - 4 {
            let kind = b[m], star = b[m + 1]
            if (kind == 0x03 || kind == 0x00) && (star == 0xFF || star == 0xFE) &&
                b[m + 2] == 0x19 && b[m + 3] == 0x06 && m >= 8 {
                head = m - 8
                break
            }
            m += 1
        }
        let hasMarker = head >= 0
        let isVideo = videoExts.contains(ext)

        var photoSize = 0
        var photoRes: String?
        if !isVideo {
            let fixed = selfPos - 7
            if selfPos >= 21 && fixed + 1 < b.count && b[fixed] == 0x19 && b[fixed + 1] == 0x06 {
                photoSize = b.u32le(fixed - 14)
                if base.hasPrefix("DJI_") && fixed + 66 <= b.count {
                    let w = b.u32le(fixed + 58), h = b.u32le(fixed + 62)
                    if (1...60000).contains(w) && (1...60000).contains(h) { photoRes = "\(w)x\(h)" }
                }
            }
            var q = lo
            while photoSize == 0 && q < markerEnd - 3 {
                if (b[q] == 0xFF || b[q] == 0xFE) && b[q + 1] == 0x19 && b[q + 2] == 0x06 {
                    let mk = q + 1
                    if mk >= 14 { photoSize = b.u32le(mk - 14) }
                    if base.hasPrefix("DJI_") && mk + 66 <= b.count {
                        let w = b.u32le(mk + 58), h = b.u32le(mk + 62)
                        if (1...60000).contains(w) && (1...60000).contains(h) { photoRes = "\(w)x\(h)" }
                    }
                    break
                }
                q += 1
            }
        }

        let path = ext.isEmpty ? mediaDir : "\(mediaDir).\(ext)"
        let thumbPath = (thumb ?? mediaDir.replacingFirst("DCIM/", with: "MISC/THM/")) + ".scr"
        let handle = hasMarker ? b.u32le(head) : 0
        let size = (isVideo && hasMarker && head >= 4) ? b.u32le(head - 4) : photoSize
        let fps = (isVideo && hasMarker) ? fpsInRange(b, head, nextHead(b, head, hi)) : nil
        let durationSec = (isVideo && hasMarker && head + 6 <= b.count) ? b.u16le(head + 4) : 0
        let starred = starFlagBySignature(b, selfPos >= 0 ? selfPos : lo, hi) ?? starFlag(b, lo, hi)
        let resIndex = (isVideo && hasMarker && head + 7 < b.count) ? Int(b[head + 7]) : -1
        let resolution = resIndex >= 0 ? resolutionForIndex(resIndex) : photoRes
        if resIndex >= 0 && resolution == nil { log("datalink: video format index \(resIndex) not mapped") }
        let tagged = selfPos >= 9 && selfPos <= b.count && b[selfPos - 7] == 0x19 && b[selfPos - 6] == 0x06
        let mediaType = tagged ? Int(b[selfPos - 9]) : -1
        let handleCandidate = (selfPos >= 17 && tagged) ? b.u32le(selfPos - 17) : 0

        return CameraFile(
            path: path, thumbPath: thumbPath, storage: 0,
            resLabel: fps.map { "\($0)fps" }, proxyPath: proxyExt.map { "\(mediaDir).\($0)" },
            handle: handle, sizeBytes: size, starred: starred, resolution: resolution,
            durationSec: durationSec, mediaType: mediaType, handleCandidate: handleCandidate
        )
    }

    static func starFlag(_ b: [UInt8], _ lo: Int, _ hi: Int) -> Bool {
        var q = lo
        while q < hi - 9 {
            if (b[q] == 0xFF || b[q] == 0xFE) && b[q + 1] == 0x19 && b[q + 2] == 0x06 { return b[q + 9] == 1 }
            q += 1
        }
        return false
    }

    static func starFlagBySignature(_ b: [UInt8], _ lo: Int, _ hi: Int) -> Bool? {
        let sig = starSignature
        var q = lo
        let end = Swift.min(hi, b.count - sig.count - 1)
        while q <= end {
            var k = 0
            while k < sig.count && b[q + k] == sig[k] { k += 1 }
            if k == sig.count { return b[q + sig.count] == 1 }
            q += 1
        }
        return nil
    }

    static func nextHead(_ b: [UInt8], _ head: Int, _ hi: Int) -> Int {
        var m = head + 9
        let stop = Swift.min(hi, b.count) - 4
        while m < stop {
            let kind = b[m], star = b[m + 1]
            if (kind == 0x03 || kind == 0x00) && (star == 0xFF || star == 0xFE) && b[m + 2] == 0x19 && b[m + 3] == 0x06 {
                return m - 8
            }
            m += 1
        }
        return hi
    }

    /// The last fps rational `num/den` (den ∈ {1000, 1001}) in `[start, end)`.
    static func fpsInRange(_ b: [UInt8], _ start: Int, _ end: Int) -> Int? {
        var fps: Int?
        var i = Swift.max(0, start)
        let stop = Swift.min(end, b.count) - 8
        while i <= stop {
            let den = b.u32le(i + 4)
            if den == 1000 || den == 1001 {
                let num = b.u32le(i)
                if (20_000...250_000).contains(num) { fps = Int((Double(num) / Double(den)).rounded()) }
            }
            i += 1
        }
        return fps
    }

    public static func resolutionForIndex(_ code: Int) -> String? {
        switch code {
        case 10: "1920x1080"
        case 12: "1920x1440"
        case 16: "3840x2160"
        case 45: "2688x1512"
        case 66: "1080x1920"
        case 67: "1512x2688"
        case 95: "2688x2016"
        case 103: "3840x2880"
        case 105: "1080x1080"
        case 106: "2160x2160"
        case 107: "3072x3072"
        case 108: "1728x3072"
        case 125: "3840x3840"
        default: nil
        }
    }

    // ---- flat scrape fallback -------------------------------------------------------------------

    static func parseFlat(_ bytes: [UInt8], log: Log) -> [CameraFile] {
        let text = bytes.isEmpty ? "" : bytes.latin1(0, bytes.count)
        let pathRe = /DCIM\/(?:DJI|CAM)_\d{3}\/(?:DJI|CAM)_\d{14}_\d{4}_D/
        let nameRe = /(?:DJI|CAM)_\d{14}_\d{4}_D\.[A-Za-z0-9]{2,4}/
        let thumbRe = /MISC\/THM\/(?:DJI|CAM)_\d{3}\/(?:DJI|CAM)_\d{14}_\d{4}_D(?:\.\w{2,4})?/

        func beforeLastDot(_ s: String) -> String { s.lastIndex(of: ".").map { String(s[..<$0]) } ?? s }
        func afterLastDot(_ s: String) -> String { s.lastIndex(of: ".").map { String(s[s.index(after: $0)...]) } ?? s }
        func afterLastSlash(_ s: String) -> String { s.split(separator: "/").last.map(String.init) ?? s }

        var bestExt: [String: String] = [:]
        var proxyByBase: [String: String] = [:]
        for m in text.matches(of: nameRe) {
            let v = String(m.output)
            let base = beforeLastDot(v), ext = afterLastDot(v).uppercased()
            if let cur = bestExt[base] {
                if primaryExts.contains(ext) && !primaryExts.contains(cur) { bestExt[base] = ext }
            } else {
                bestExt[base] = ext
            }
            if proxyExts.contains(ext) { proxyByBase[base] = ext }
        }
        var thumbByBase: [String: String] = [:]
        for m in text.matches(of: thumbRe) {
            let v = String(m.output)
            thumbByBase[beforeLastDot(afterLastSlash(v))] = v.contains(".") ? v : v + ".scr"
        }
        log("datalink: flat scrape exts=\(Set(bestExt.values).sorted()) proxies=\(Set(proxyByBase.values).sorted())")
        let paths = Set(text.matches(of: pathRe).map { String($0.output) }).sorted()
        return paths.map { p in
            let base = afterLastSlash(p)
            let ext = bestExt[base]
            let mediaPath = ext.map { "\(p).\($0)" } ?? p
            let thumb = thumbByBase[base] ?? (p.replacingFirst("DCIM/", with: "MISC/THM/") + ".scr")
            let isVid = ext.map { videoExts.contains($0) } ?? false
            let nameBytes = ext.map { Array("\(base).\($0)".utf8) }
            let namePos = nameBytes.flatMap { bytes.firstIndex(of: $0) } ?? -1
            let fps = (isVid && namePos >= 0) ? fpsInRange(bytes, namePos - 220, namePos) : nil
            let start = namePos >= 0 ? recordStart(bytes, namePos) : -1
            let handle = start >= 0 ? bytes.u32le(start) : 0
            let size = (isVid && start >= 0 && start + 42 <= bytes.count) ? bytes.u32le(start + 38) : 0
            return CameraFile(path: mediaPath, thumbPath: thumb, resLabel: fps.map { "\($0)fps" },
                              proxyPath: proxyByBase[base].map { "\(p).\($0)" }, handle: handle, sizeBytes: size)
        }
    }

    static func recordStart(_ b: [UInt8], _ namePos: Int) -> Int {
        var i = Swift.min(namePos, b.count) - 4
        let lo = Swift.max(0, namePos - 400)
        while i >= lo {
            if b[i] == 0x03 && b[i + 1] == 0xFF && b[i + 2] == 0x19 && b[i + 3] == 0x06 { return i - 8 >= 0 ? i - 8 : -1 }
            i -= 1
        }
        return -1
    }
}

extension String {
    func replacingFirst(_ target: String, with replacement: String) -> String {
        guard let r = range(of: target) else { return self }
        return replacingCharacters(in: r, with: replacement)
    }
}
