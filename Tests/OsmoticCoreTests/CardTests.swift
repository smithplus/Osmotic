import Foundation
import Testing

@testable import OsmoticCore

/// A card, as an Osmo writes one: DCIM/DJI_001 with clips, their proxies and their audio.
private func makeCard(_ files: [(String, Int)]) throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("card-\(UUID().uuidString)", isDirectory: true)
    let dir = root.appendingPathComponent("DCIM/DJI_001", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (name, size) in files {
        let data = Data(repeating: 0x7A, count: size)
        try data.write(to: dir.appendingPathComponent(name))
    }
    return root
}

@Suite struct CardScannerTests {
    @Test func recognizesACameraCardAndIgnoresAPlainDisk() throws {
        let card = try makeCard([("DJI_20260827200600_0001_D.MP4", 32)])
        #expect(CardScanner.isCameraCard(card))
        let plain = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        #expect(!CardScanner.isCameraCard(plain))
    }

    @Test func listsClipsNewestFirstWithTheirRealSizes() throws {
        let card = try makeCard([
            ("DJI_20260827200600_0001_D.MP4", 100),
            ("DJI_20260827200600_0001_D.LRF", 10),
            ("DJI_20260827200600_0001_D.WAV", 5),
            ("DJI_20260903190434_0006_D.MP4", 200),
            ("DJI_20260903190434_0006_D.LRF", 20),
        ])
        let files = CardScanner.files(on: card)
        #expect(files.count == 2, "only the clips are listed; LRF and WAV are companions")
        #expect(files.first?.name == "DJI_20260903190434_0006_D.MP4", "newest first")
        #expect(files.first?.sizeBytes == 200)
        #expect(files.first?.path == "DCIM/DJI_001/DJI_20260903190434_0006_D.MP4")
        #expect(files.first?.proxyPath == "DCIM/DJI_001/DJI_20260903190434_0006_D.LRF")
        #expect(files.last?.captureDate != nil, "the date comes from the name, as over Wi-Fi")
        #expect(files.allSatisfy { $0.isVideo })
    }

    @Test func tellsAnUnreadableCardApartFromNoCard() throws {
        let card = try makeCard([("DJI_20260827200600_0001_D.MP4", 32)])
        let dcim = card.appendingPathComponent("DCIM")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dcim.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dcim.path) }
        #expect(CardScanner.access(to: card) == .denied, "a DCIM that can't be read is reported, not hidden")
        let plain = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        #expect(CardScanner.access(to: plain) == .notACard, "no DCIM at all is simply not a card")
    }

    @Test func findsTheCompanionsOfAClip() throws {
        let card = try makeCard([
            ("DJI_20260827200600_0001_D.MP4", 10),
            ("DJI_20260827200600_0001_D.WAV", 4),
            ("DJI_20260827200600_0001_D.LRF", 2),
        ])
        let clip = CardScanner.files(on: card)[0]
        #expect(CardScanner.sidecars(of: clip, on: card) == ["DCIM/DJI_001/DJI_20260827200600_0001_D.WAV"])
        let withProxy = CardScanner.sidecars(of: clip, on: card, includeProxy: true)
        #expect(withProxy.contains("DCIM/DJI_001/DJI_20260827200600_0001_D.LRF"))
    }

    @Test func onlyResolvesPathsInsideTheCardsDCIM() throws {
        let card = try makeCard([("DJI_20260827200600_0001_D.MP4", 10)])
        #expect(CardScanner.url(for: "DCIM/DJI_001/DJI_20260827200600_0001_D.MP4", on: card) != nil)
        #expect(CardScanner.url(for: "../../etc/passwd", on: card) == nil, "no climbing out")
        #expect(CardScanner.url(for: "/etc/passwd", on: card) == nil, "no absolute paths")
        #expect(CardScanner.url(for: "MISC/note.txt", on: card) == nil, "only DCIM is read")
    }
}

@Suite struct CardCopierTests {
    private func temp() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func copiesAFileAndReportsProgress() async throws {
        let card = try makeCard([("DJI_20260827200600_0001_D.MP4", CardCopier.block + 1234)])
        let source = CardScanner.url(for: "DCIM/DJI_001/DJI_20260827200600_0001_D.MP4", on: card)!
        let dest = temp().appendingPathComponent("2026-08-27/DJI_20260827200600_0001_D.MP4")
        let seen = Reports()
        let outcome = await CardCopier().copy(from: source, to: dest) { seen.add($0) }
        #expect(outcome == .saved(dest))
        #expect(FileManager.default.fileExists(atPath: dest.path), "the day folder is created")
        let size = (try dest.resourceValues(forKeys: [.fileSizeKey])).fileSize
        #expect(size == CardCopier.block + 1234)
        #expect(seen.values.count >= 2, "progress arrives per block")
        #expect(seen.values.last == CardCopier.block + 1234)
        #expect(!FileManager.default.fileExists(atPath: dest.appendingPathExtension("part").path), "no leftovers")
    }

    @Test func leavesAFileThatIsAlreadyThere() async throws {
        let card = try makeCard([("DJI_20260827200600_0001_D.MP4", 64)])
        let source = CardScanner.url(for: "DCIM/DJI_001/DJI_20260827200600_0001_D.MP4", on: card)!
        let dest = temp().appendingPathComponent("DJI_20260827200600_0001_D.MP4")
        #expect(await CardCopier().copy(from: source, to: dest) == .saved(dest))
        let stamp = (try dest.resourceValues(forKeys: [.contentModificationDateKey])).contentModificationDate
        #expect(await CardCopier().copy(from: source, to: dest) == .skipped(dest))
        let after = (try dest.resourceValues(forKeys: [.contentModificationDateKey])).contentModificationDate
        #expect(stamp == after, "the file on the Mac is untouched")
    }

    @Test func aHalfCopiedFileNeverLooksFinished() async throws {
        let card = try makeCard([("DJI_20260827200600_0001_D.MP4", 32)])
        let source = CardScanner.url(for: "DCIM/DJI_001/DJI_20260827200600_0001_D.MP4", on: card)!
        let dest = temp().appendingPathComponent("DJI_20260827200600_0001_D.MP4")
        let task = Task { await CardCopier().copy(from: source, to: dest) }
        task.cancel()
        let outcome = await task.value
        if outcome == .cancelled {
            #expect(!FileManager.default.fileExists(atPath: dest.path))
            #expect(!FileManager.default.fileExists(atPath: dest.appendingPathExtension("part").path))
        } else {
            #expect(outcome == .saved(dest), "it finished before the cancel landed, which is fine")
        }
    }

    @Test func saysSoWhenTheCardIsGone() async throws {
        let card = try makeCard([("DJI_20260827200600_0001_D.MP4", 16)])
        let source = CardScanner.url(for: "DCIM/DJI_001/DJI_20260827200600_0001_D.MP4", on: card)!
        try FileManager.default.removeItem(at: source)
        let outcome = await CardCopier().copy(from: source, to: temp().appendingPathComponent("x.MP4"))
        guard case .failed = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
    }
}

/// Progress callbacks arrive on the copier's task; collect them behind a lock.
private final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [Int] = []
    func add(_ v: Int) {
        lock.lock()
        seen.append(v)
        lock.unlock()
    }
    var values: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }
}

@Suite struct CardProbeTests {
    @Test func measuresWhatTheCardReadsAndTurnsItIntoMinutes() throws {
        // A file big enough to read past the warm-up block.
        let card = try makeCard([("DJI_20260827200600_0001_D.MP4", CardProbe.block * 6)])
        let speed = CardProbe.readSpeed(on: card, seconds: 0.2)
        #expect(speed != nil && speed! > 0, "a local file reads at some measurable rate")
        #expect(CardProbe.minutes(forBytes: 36_000_000_000, at: 30) == 20, "36 GB at 30 MB/s is about 20 minutes")
        #expect(CardProbe.minutes(forBytes: 0, at: 30) == nil)
        #expect(CardProbe.minutes(forBytes: 1_000_000, at: 0) == nil, "no speed, no estimate")
    }

    @Test func saysNothingWhenThereIsNothingToMeasure() throws {
        let card = try makeCard([("DJI_20260827200600_0001_D.MP4", 1024)])
        #expect(CardProbe.readSpeed(on: card) == nil, "too small to mean anything")
    }
}
