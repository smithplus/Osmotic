import Foundation
import Testing
@testable import OsmoticCore

/// File names come from the camera — an untrusted network peer — and must never reach outside the
/// download folder or replace anything already on disk.
@Suite struct PathSafetyTests {
    @Test func realCameraNamesPassThrough() {
        for name in ["DJI_20260804154141_0728_D.MP4", "DJI_0001.JPG", "DJI_20260804154141_0728_D.LRF"] {
            #expect(CameraFile.safeFileName(name) == name)
        }
    }

    @Test func dotsSeparatorsAndOddCharactersAreNeutralised() {
        #expect(CameraFile.safeFileName("..") == "file")
        #expect(CameraFile.safeFileName(".") == "file")
        #expect(CameraFile.safeFileName("") == "file")
        #expect(CameraFile.safeFileName(".hidden.mp4") == "hidden.mp4")
        #expect(CameraFile.safeFileName("a/../b") == "a_.._b")
        #expect(CameraFile.safeFileName("x\u{0}y:z") == "x_y_z")
        #expect(CameraFile.safeFileName(String(repeating: "a", count: 400)).count == 200)
    }

    @Test func localNameOfATraversalPathStaysInside() {
        let f = CameraFile(path: "DCIM/..", thumbPath: "", storage: 1, sizeBytes: 10)
        let root = URL(fileURLWithPath: "/tmp/osmotic-root", isDirectory: true)
        let dest = root.appendingPathComponent(f.localName)
        #expect(dest.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path)
    }

    @Test func downloaderRefusesUnsafeDestinationAndDeletesNothing() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("osmotic-safety-\(UUID().uuidString)")
        let keep = base.appendingPathComponent("keep.txt")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try Data("precious".utf8).write(to: keep)
        defer { try? FileManager.default.removeItem(at: base) }

        // `<base>/DJI/..` — the folder above the (missing) download folder.
        let dl = FileDownloader(http: CameraHTTP(ip: "127.0.0.1", port: 9), log: { _ in })
        let unsafe = base.appendingPathComponent("DJI").appendingPathComponent("..")
        let r = await dl.download(urlPath: "/x", to: unsafe, expectedSize: 1) { _ in }
        guard case .failed = r else { Issue.record("expected .failed, got \(r)"); return }
        #expect(FileManager.default.fileExists(atPath: keep.path))
    }
}
