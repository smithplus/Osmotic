import Foundation
import Testing
@testable import OsmoticCore

@Suite struct DumlFramingTests {
    /// Frames lifted verbatim from MEDIA_PROTOCOL.md's decoder links — real captures.
    @Test func `the pairing frame is byte-identical to a captured one`() {
        let f = OsmoCommands.setPairingPin("osmo", id: 0xA000)
        #expect(f.hexString == "553304c2020700a0400745203238346165356238643736623333373561303461363431376164373162656133046f736d6f8c02")
    }

    @Test func `session ping and wake match the Mimo capture`() {
        #expect(OsmoCommands.sessionPing(OsmoCommands.sessionWake, id: 0xCB1B).hexString == "550f04a202f01bcb40002b04009ab9")
        #expect(OsmoCommands.sessionPing(OsmoCommands.sessionKeepalive, id: 0xCB1B).hexString == "550f04a202f01bcb40002b0101abd6")
        let wake = OsmoCommands.session5310(id: 0xCB1D)
        #expect(wake[5] == 0x1C)
        #expect(wake.hexString == "55110492021c1dcb40531000000000894a")
    }

    @Test func `wifi getters match their captured frames`() {
        #expect(OsmoCommands.wifiQuery(0x07, id: 0xA000).hexString == "550d0433020700a04007077472")
        #expect(OsmoCommands.wifiQuery(0x0E, id: 0xA000).hexString == "550d0433020700a040070eb5ef")
    }

    @Test func `a datalink list query encodes like the capture`() {
        let payload = Pagination.listCommand(ctr: 1, cursor: 1)
        let f = DjiMessage(target: 0x0102, id: 0xA000, type: (2 << 5) | (0x00 << 8) | (0x26 << 16), payload: payload).encode()
        #expect(f.hexString == "553704f9020100a04000264a002a10010000000000010000002d000d0100ffffffffffffffff0001000000000000000000000000008185")
    }

    @Test func `decode round-trips and rejects a corrupt header`() throws {
        let m = DjiMessage(target: 0x0702, id: 0x1234, type: 0x112233, payload: [1, 2, 3])
        let back = try #require(DjiMessage(frame: m.encode()))
        #expect(back == m)
        var bad = m.encode()
        bad[2] = 0x05
        #expect(DjiMessage(frame: bad) == nil)
        #expect(back.flags == 0x33 && back.cmdSet == 0x22 && back.cmdId == 0x11)
    }

    @Test func `the accumulator splits two frames and joins a split one`() {
        let a = OsmoCommands.wifiQuery(0x07)
        let b = OsmoCommands.wifiQuery(0x0E)
        var acc = DumlFrameAccumulator()
        #expect(acc.append(a + b).count == 2)
        #expect(acc.append(Array(a[0..<5])).isEmpty)
        let joined = acc.append(Array(a[5...]))
        #expect(joined.count == 1 && joined[0].cmdId == 0x07)
    }

    @Test func `a request is answered with swapped target and flags C0`() throws {
        let req = DjiMessage(target: 0x0207, id: 0x1111, type: 0x460740, payload: [0x01])
        let resp = try #require(DjiMessage(frame: OsmoCommands.response(to: req)))
        #expect(resp.target == 0x0702)
        #expect(resp.flags == 0xC0 && resp.cmdSet == 0x07 && resp.cmdId == 0x46)
        #expect(resp.id == 0x1111)
    }

    @Test func `pack-string replies parse`() {
        #expect(OsmoCommands.parseStatusPackString([0x00, 0x04] + Array("abcd".utf8)) == "abcd")
        #expect(OsmoCommands.parseStatusPackString([0x00, 0x09, 0x41]) == nil)
    }
}

@Suite struct DatalinkHeaderTests {
    @Test func `transport header carries session and seq with an xor trailer`() {
        let h = DatalinkHeaders.udpHeader(pktType: 0x05, payloadLen: 40, sessionId: 0x2965, seq: 0x87C0)
        #expect(h.count == 8)
        #expect(Array(h[2..<7]) == [0x65, 0x29, 0xC0, 0x87, 0x05])
        #expect(h[7] == h[0..<7].reduce(0, ^))
        #expect(h.u16le(0) & 0x3FFF == 48 && h.u16le(0) & 0x8000 != 0)
    }

    @Test func `the ack trails our own seq by one step and wraps`() {
        let rt = DatalinkHeaders.routingHeader(seq: 0x1570, cmdCounter: 3, drone: false)
        #expect(rt.count == 12)
        #expect(rt.u16le(0) == 0x1568 && rt.u16le(2) == 0x1570 && rt[8] == 3)
        #expect(DatalinkHeaders.routingHeader(seq: 4, cmdCounter: 0, drone: false).u16le(0) == 0xFFFC)
    }

    @Test func `frame scanning finds nested and long frames`() {
        let inner = DjiMessage(target: 0x0702, id: 10, type: 0x270040, payload: [0x4A, 0x01]).encode()
        let outer = DjiMessage(target: 0xE93B, id: 10, type: 0x015140, payload: inner).encode()
        let sets = DumlScanner.frames(in: outer).map { [$0.cmdSet, $0.cmdId] }
        #expect(sets.contains([0x51, 0x01]) && sets.contains([0x00, 0x27]))

        let long = DjiMessage(target: 0x0702, id: 10, type: 0x270040, payload: [UInt8](repeating: 7, count: 400)).encode()
        #expect(long.count > 255 && long[2] == 0x05)
        #expect(DumlScanner.frames(in: long).first?.payload.count == 400)
    }

    @Test func `findReply skips the empty transport ack`() {
        let ack = DjiMessage(target: 0x0702, id: 10, type: 0x280040, payload: []).encode()
        let real = DjiMessage(target: 0x0702, id: 10, type: 0x280040, payload: [0, 0]).encode()
        #expect(DumlScanner.findReply([ack + real], set: 0x00, cmd: 0x28) == [0, 0])
        #expect(DumlScanner.findReply([ack], set: 0x00, cmd: 0x28) == nil)
    }

    @Test func `registration subscription matches Mimo's layout`() {
        let s = CameraSession.subscription("cam_status", subId: 0x69DF)
        #expect(s.hexString == "02020000df69000000000010000a0063616d5f73746174757300000000")
    }
}

@Suite struct AdvertAndModelTests {
    @Test func `pocket 3 resolves by classic id and pins storage 0`() {
        let payload = [UInt8](hex: "200040e47a2c78d1e9")
        #expect(BleAdvert.modelId(payload) == 0x0020)
        let m = CameraModel.resolve(modelId: 0x0020, name: "OsmoPocket3-D1E9")
        #expect(m.name == "Osmo Pocket 3")
        #expect(m.datalinkPort == 9004 && m.tcpPoke && m.singleSdStorage)
    }

    @Test func `pocket 4 pro resolves through the new format`() {
        let d = BleAdvert.decode([UInt8](hex: "000000ee0004bd6e5620da000010"))
        #expect(d.newFormat && d.rawProductType == 218 && d.modelId == 0x0022)
    }

    @Test func `a short payload with the flag set falls back to classic`() {
        let d = BleAdvert.decode([UInt8](hex: "190000040504"))
        #expect(!d.newFormat && d.rawProductType == nil && d.modelId == 0x0019)
    }

    @Test func `name fallback and xtra rebrand`() {
        #expect(CameraModel.resolve(modelId: nil, name: "OsmoPocket4P-6E55").name == "Osmo Pocket 4 Pro")
        let x = CameraModel.resolve(modelId: 0x0015, name: "XtraEdgePro-1234", brand: .xtra)
        #expect(x.name == "Xtra Edge Pro" && x.datalinkPort == 10004 && !x.tcpPoke)
        #expect(Brand.of(name: nil, manufacturerPayload: [UInt8](hex: "150000ec9eea112233"), djiCompanyId: true) == .xtra)
    }

    @Test func `manufacturer data splits the little-endian company id`() {
        let s = BleAdvert.splitManufacturerData([0xAA, 0x08, 0x20, 0x00])
        #expect(s?.companyId == 0x08AA && s?.payload == [0x20, 0x00])
    }
}

@Suite struct StatusTests {
    func status(_ hex: String) -> CameraStatus {
        var t = StatusTracker()
        t.apply(set: 0x02, id: 0xDC, payload: [UInt8](hex: hex), log: { _ in })
        return t.status
    }

    @Test func `pocket 3 single-store frame decodes the card`() {
        let s = status("001201000001b9db0100230a0100000000004e180000")
        #expect(s.sdTotalMb == 121_785 && s.sdFreeMb == 68_131 && s.sdInserted && s.internalTotalMb == 0)
    }

    @Test func `a camera with no card reports zero capacity`() {
        let s = status("11120200000200000000000000000000000000000000010154bf000003b50000")
        #expect(s.sdTotalMb == 0 && !s.sdInserted && s.internalTotalMb == 48_980)
    }

    @Test func `the playback bit is read from the flags word`() {
        var t = StatusTracker()
        var p = [UInt8](repeating: 0, count: 60)
        p[3] = 0x40
        t.apply(set: 0x02, id: 0x80, payload: p, log: { _ in })
        #expect(t.playbackReported == true)
    }
}

@Suite struct EmbeddedJpegTests {
    @Test func `the EXIF thumbnail is lifted out of APP1`() {
        let thumb: [UInt8] = [0xFF, 0xD8, 0x01, 0x02, 0xFF, 0xD9]
        let app1Body: [UInt8] = Array("Exif\0\0".utf8) + thumb
        let len = app1Body.count + 2
        let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE1, UInt8(len >> 8), UInt8(len & 0xFF)] + app1Body + [0xFF, 0xDA]
        #expect(EmbeddedJpeg.fromHeader(jpeg) == thumb)
    }
}
