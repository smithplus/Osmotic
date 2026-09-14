import Foundation
import Testing

@testable import OsmoticCore

func fixture(_ name: String) throws -> [UInt8] {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return [UInt8](try Data(contentsOf: url))
}

func golden(_ name: String) throws -> [String] {
    let url = try #require(
        Bundle.module.url(forResource: "\(name).golden", withExtension: "txt", subdirectory: "Fixtures/golden"))
    let text = try String(contentsOf: url, encoding: .utf8)
    return text.trimmingCharacters(in: CharacterSet(charactersIn: "\n")).components(separatedBy: "\n")
}

/// The same canonical line the upstream Kotlin golden test prints: every field the UI reads.
func canon(_ files: [CameraFile]) -> [String] {
    files.map { f in
        String(
            format: "%@|%@|%08lx|%08lx|%ld|%@|%@|%ld|%@|%ld|%ld|%@",
            f.name, f.ext, f.handle, f.cmdHandle, f.sizeBytes, f.resolution ?? "", f.resLabel ?? "",
            f.durationSec, f.starred ? "true" : "false", f.mediaType, f.group, f.deletable ? "true" : "false")
    }.sorted()
}

/// Golden-master snapshot of the decoder across every captured manifest, byte-for-byte the upstream
/// expectations. Any field that moves on any body fails here.
@Suite struct ManifestGoldenTests {
    @Test(arguments: [
        "nano_45.bin", "nano_delete.bin", "xtra_13.bin", "xtra_delete.bin", "oa6_sd_3.bin",
        "oa6_internal_2.bin", "op3_5_starred.bin", "op3_9_pano.bin", "op3_9_stars_moved.bin",
        "op3_11_panos.bin", "op3_15.bin", "op3_29.bin", "op4_45.bin", "oa4_45.bin",
    ])
    func `decode matches the upstream golden snapshot`(fixtureName: String) throws {
        let got = canon(ManifestDecoder.decodeBlob(try fixture(fixtureName)))
        let want = try golden(fixtureName)
        #expect(got.count == want.count, "\(fixtureName): record count moved")
        for (g, w) in zip(got, want) where g != w {
            Issue.record("\(fixtureName)\n got: \(g)\nwant: \(w)")
        }
    }
}

@Suite struct Pocket3Tests {
    func decode(_ name: String) throws -> [CameraFile] { ManifestDecoder.decodeBlob(try fixture(name)) }

    @Test func `all 15 records decode, with the _OP3 suffix`() throws {
        let files = try decode("op3_15.bin")
        #expect(files.count == 15)
        #expect(Set(files.map(\.path)).count == 15)
        #expect(files.allSatisfy { $0.name.contains("_D_OP3.") })
        #expect(files.filter { $0.ext == "MP4" }.count == 15)
        for f in files { #expect(f.handle == 0x0004_0000 + f.seq * 0x10) }
    }

    @Test func `a still reports its own size`() throws {
        let files = try decode("op3_11_panos.bin")
        func named(_ n: String) -> CameraFile { files.first { $0.name.contains(n) }! }
        #expect(named("_0001_D").sizeBytes == 53_835_384)
        #expect(named("_0002_D").sizeBytes == 3_751_936)
        #expect(named("_0005_D").sizeBytes == 69_361_901)
        #expect(named("_0006_D").sizeBytes == 4_517_888)
        #expect(files.filter(\.isPanorama).count == 2)
    }

    @Test func `favourites track the camera on videos and stills`() throws {
        let before = try decode("op3_9_pano.bin")
        let after = try decode("op3_9_stars_moved.bin")
        func star(_ list: [CameraFile], _ n: String) -> Bool { list.first { $0.name.contains(n) }!.starred }
        #expect(star(before, "_0001_D") && !star(after, "_0001_D"))
        #expect(!star(before, "_0005_D") && star(after, "_0005_D"))
        #expect(!star(before, "_0002_D") && star(after, "_0002_D"))
        #expect(before.filter(\.starred).count == 1)
        #expect(after.filter(\.starred).count == 2)
    }

    @Test func `records without a filename field borrow their extension from the media type`() throws {
        let raw = ManifestDecoder.decodeBlob(try fixture("op3_29.bin"))
        #expect(raw.filter { $0.ext.isEmpty }.count == 2, "upstream leaves these two bare")
        let fixed = ManifestDecoder.inferMissingExtensions(raw)
        #expect(fixed.allSatisfy { !$0.ext.isEmpty })
        #expect(fixed.first { $0.name.hasPrefix("DJI_20260804155147_0742_D") }?.ext == "JPG")
    }

    @Test func `dates and sequence come from the filename`() throws {
        let f = try decode("op3_15.bin")[0]
        #expect(f.timestamp.count == 14)
        #expect(f.captureDate != nil)
        #expect(f.seq > 0)
        #expect(f.thumbPath.hasPrefix("MISC/THM/"))
        #expect(f.previewURLPaths.first?.hasSuffix(".LRF") == true)
    }
}

@Suite struct ReassemblyTests {
    @Test func `nano raw datagram blob reassembles to 45 records`() throws {
        let files = ManifestDecoder.decodeBlob(try fixture("nano_45.bin"))
        #expect(files.count == 45)
        let f = try #require(files.first { $0.name.contains("_0264_D") })
        #expect(f.path == "DCIM/DJI_001/DJI_20260712173055_0264_D.MP4")
        #expect(f.thumbPath == "MISC/THM/DJI_001/DJI_20260712173055_0264_D.scr")
        #expect(f.resLabel == "25fps")
    }

    @Test func `xtra raw blob reassembles to 13 records`() throws {
        let files = ManifestDecoder.decodeBlob(try fixture("xtra_13.bin"))
        #expect(files.count == 13)
        #expect(files.allSatisfy { $0.path.hasPrefix("DCIM/CAM_001/CAM_") })
        #expect(files.filter { $0.ext == "JPG" }.count == 12)
    }

    @Test func `the end marker is found on a final page and not on a full one`() throws {
        #expect(ManifestDecoder.hasEndMarker(ManifestDecoder.manifestBytes(try fixture("xtra_13.bin"))))
        #expect(!ManifestDecoder.hasEndMarker(ManifestDecoder.manifestBytes(try fixture("nano_45.bin"))))
    }
}

@Suite struct PaginationTests {
    @Test func `the newest-page query is byte-identical to the proven blob`() {
        let q = Pagination.listCommand(ctr: 1, cursor: Pagination.newestSd)
        #expect(q.hexString == "4a002a10010000000000010000002d000d0100ffffffffffffffff000100000000000000000000000000")
    }

    @Test func `a cursor lands little-endian at bytes 10 to 13`() {
        let q = Pagination.listCommand(ctr: 2, cursor: 0x4010_36C0)
        #expect(q[4] == 2)
        #expect(Array(q[10..<14]) == [0xC0, 0x36, 0x10, 0x40])
    }

    @Test func `an SD-only card pages on its own store`() {
        var p = Pagination()
        let files = (1...45).map { i -> CameraFile in
            var f = CameraFile(
                path: String(format: "DCIM/DJI_001/DJI_20260101120000_%04d_D.MP4", 100 - i),
                thumbPath: "", handle: 0x0004_0000 + (100 - i) * 0x10)
            f.storage = 0; f.storageKnown = true
            return f
        }
        p.seed(with: files, slices: [:])
        #expect(p.moreAvailable, "a full SD page must leave more to fetch")
        #expect(p.sdCursor == 0x0004_0000 + 55 * 0x10)
        #expect(p.internalCursor == Pagination.newestInternal)
    }
}
