import Testing

@testable import OsmoticCore

/// The library's order (newest first, the download queue oldest first) and how a listed page joins it.
@Suite struct LibraryOrderTests {
    private func file(_ name: String, storage: Int = 1) -> CameraFile {
        CameraFile(path: "DCIM/DJI_001/" + name, thumbPath: "", storage: storage)
    }

    private let older = "DJI_20260329115359_0211_D.MP4"
    private let sameStampLowSeq = "DJI_20260804154141_0727_D.MP4"
    private let sameStampHighSeq = "DJI_20260804154141_0728_D.MP4"
    private let newest = "DJI_20260901090000_0001_D.MP4"

    @Test func newestFirstBreaksStampTiesBySequence() {
        let files = [older, sameStampLowSeq, newest, sameStampHighSeq].map { file($0) }
        #expect(files.newestFirst().map(\.name) == [newest, sameStampHighSeq, sameStampLowSeq, older])
    }

    @Test func oldestFirstIsTheReverseOrder() {
        let files = [sameStampHighSeq, newest, older, sameStampLowSeq].map { file($0) }
        #expect(files.oldestFirst().map(\.name) == [older, sameStampLowSeq, sameStampHighSeq, newest])
    }

    @Test func filesThatTieKeepTheirOrder() {
        // No stamp and no sequence number: every key ties.
        let files = ["b.JPG", "a.JPG", "c.JPG"].map { file($0) }
        #expect(files.newestFirst().map(\.name) == ["b.JPG", "a.JPG", "c.JPG"])
        #expect(files.oldestFirst().map(\.name) == ["b.JPG", "a.JPG", "c.JPG"])
    }

    @Test func mergeAddsOnlyFilesNotAlreadyInTheLibrary() {
        let library = [sameStampHighSeq, older].map { file($0) }
        let page = [newest, sameStampHighSeq, sameStampLowSeq].map { file($0) }
        let merged = library.merging(page)
        #expect(merged.added.map(\.name) == [newest, sameStampLowSeq])
        #expect(merged.files.map(\.name) == [newest, sameStampHighSeq, sameStampLowSeq, older])
    }

    @Test func mergeMatchesByIdSoTheSameNameOnAnotherStoreIsNew() {
        let library = [file(newest, storage: 1)]
        let merged = library.merging([file(newest, storage: 0)])
        #expect(merged.added.map(\.id) == ["0:DCIM/DJI_001/" + newest])
        #expect(merged.files.count == 2)
    }

    @Test func mergePlacesTiesByWhereThePageCameFrom() {
        let library = [file("x.JPG")]
        let page = [file("y.JPG")]
        #expect(library.merging(page).files.map(\.name) == ["y.JPG", "x.JPG"])
        #expect(library.merging(page, pageIsOlder: true).files.map(\.name) == ["x.JPG", "y.JPG"])
    }

    @Test func mergeResortsEvenWhenNothingIsNew() {
        let library = [older, newest].map { file($0) }
        let merged = library.merging([file(older)])
        #expect(merged.added.isEmpty)
        #expect(merged.files.map(\.name) == [newest, older])
    }

    @Test func emptyInputsAreStable() {
        let empty: [CameraFile] = []
        #expect(empty.newestFirst().isEmpty)
        #expect(empty.oldestFirst().isEmpty)
        let none = empty.merging([])
        #expect(none.files.isEmpty && none.added.isEmpty)
        let library = [newest, older].map { file($0) }
        let unchanged = library.merging([])
        #expect(unchanged.added.isEmpty)
        #expect(unchanged.files == library)
        let fromEmpty = empty.merging(library)
        #expect(fromEmpty.added == library)
        #expect(fromEmpty.files == library)
    }
}
