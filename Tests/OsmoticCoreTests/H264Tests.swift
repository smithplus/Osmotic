import Testing
@testable import OsmoticCore

@Suite struct H264Tests {
    @Test func splitsOnThreeAndFourByteStartCodes() {
        let sps: [UInt8] = [0x67, 0x64, 0x00, 0x1F]
        let pps: [UInt8] = [0x68, 0xEE, 0x3C, 0x80]
        let idr: [UInt8] = [0x65, 0x88, 0x84, 0x00, 0x00, 0x03, 0x01]   // an emulation-prevented 00 00 03 stays inside
        let stream = [0, 0, 0, 1] + sps + [0, 0, 1] + pps + [0, 0, 0, 1] + idr
        let units = H264AnnexB.units(stream)
        #expect(units == [sps, pps, idr])
        #expect(units.map(H264AnnexB.type) == [7, 8, 5])
    }

    @Test func dropsLeadingGarbageAndEmptyUnits() {
        let units = H264AnnexB.units([0xAA, 0xBB, 0, 0, 1, 0, 0, 1, 0x41, 0x9A])
        #expect(units == [[0x41, 0x9A]])
    }

    @Test func avccPrefixesBigEndianLengths() {
        #expect(H264AnnexB.avcc([[0x65, 0x01], [0x41]]) == [0, 0, 0, 2, 0x65, 0x01, 0, 0, 0, 1, 0x41])
    }
}
