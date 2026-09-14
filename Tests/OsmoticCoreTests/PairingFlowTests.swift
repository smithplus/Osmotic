import Foundation
import Testing
@testable import OsmoticCore

/// Drives the pairing conversation with a manual clock and a scripted camera.
final class FakeClock {
    var now: TimeInterval = 0
    var pending: [(at: TimeInterval, body: () -> Void)] = []
    func schedule(_ delay: TimeInterval, _ body: @escaping () -> Void) { pending.append((now + delay, body)) }
    func advance(to t: TimeInterval) {
        while let next = pending.enumerated().filter({ $0.element.at <= t }).min(by: { $0.element.at < $1.element.at }) {
            pending.remove(at: next.offset)
            now = next.element.at
            next.element.body()
        }
        now = t
    }
}

@Suite struct PairingFlowTests {
    func reply(_ cmdId: Int, _ payload: [UInt8]) -> DjiMessage {
        DjiMessage(target: 0x0207, id: 0x8000, type: 0xC0 | (0x07 << 8) | (cmdId << 16), payload: payload)
    }

    func frames(_ writes: [[UInt8]]) -> [String] {
        writes.compactMap { DjiMessage(frame: $0) }.map { String(format: "%02x/%02x", $0.cmdSet, $0.cmdId) }
    }

    @Test func `an already-paired camera hands over its Wi-Fi`() {
        let clock = FakeClock()
        var writes: [[UInt8]] = []
        var events: [PairingFlow.Event] = []
        let flow = PairingFlow(bleName: "OsmoPocket3-ABCD", savedPassword: nil)
        flow.write = { writes.append($0) }
        flow.emit = { events.append($0) }
        flow.schedule = clock.schedule

        flow.onReady()
        clock.advance(to: 0.2)
        #expect(frames(writes) == ["00/2b", "07/45"])

        flow.onMessage(reply(0x45, [0x00, 0x01]))
        #expect(events == [.paired])
        clock.advance(to: 1.7)
        #expect(frames(writes).suffix(3) == ["53/10", "07/07", "07/0e"])

        flow.onMessage(reply(0x07, [0x00] + OsmoCommands.packString("OsmoPocket3-ABCD")))
        flow.onMessage(reply(0x0E, [0x00] + OsmoCommands.packString("secret123")))
        #expect(events.last == .credentials(ssid: "OsmoPocket3-ABCD", password: "secret123"))
        clock.advance(to: 10)
        #expect(events.count == 2, "no fallback once credentials arrived")
    }

    @Test func `first pairing waits for approval, then answers the 0x46 request`() {
        let clock = FakeClock()
        var writes: [[UInt8]] = []
        var events: [PairingFlow.Event] = []
        let flow = PairingFlow(bleName: "OsmoPocket3-ABCD", savedPassword: nil)
        flow.write = { writes.append($0) }
        flow.emit = { events.append($0) }
        flow.schedule = clock.schedule
        flow.onReady()
        clock.advance(to: 0.2)
        flow.onMessage(reply(0x45, [0x00, 0x02]))
        #expect(events == [.approvalRequired])

        let approval = DjiMessage(target: 0x0207, id: 0x1234, type: 0x40 | (0x07 << 8) | (0x46 << 16), payload: [0x01])
        writes.removeAll()
        flow.onMessage(approval)
        let resp = DjiMessage(frame: writes[0])
        #expect(resp?.flags == 0xC0 && resp?.cmdId == 0x46 && resp?.id == 0x1234)
        #expect(events == [.approvalRequired, .paired])
    }

    @Test func `no credentials falls back to the saved password`() {
        let clock = FakeClock()
        var events: [PairingFlow.Event] = []
        let flow = PairingFlow(bleName: "OsmoPocket3-ABCD", savedPassword: "saved!")
        flow.emit = { events.append($0) }
        flow.schedule = clock.schedule
        flow.onReady()
        flow.onMessage(reply(0x45, [0x00, 0x01]))
        clock.advance(to: 7)
        #expect(events == [.paired, .credentials(ssid: "OsmoPocket3-ABCD", password: "saved!")])
    }

    @Test func `pairing is re-sent while the camera stays silent`() {
        let clock = FakeClock()
        var writes: [[UInt8]] = []
        let flow = PairingFlow(bleName: "x", savedPassword: nil)
        flow.write = { writes.append($0) }
        flow.schedule = clock.schedule
        flow.onReady()
        clock.advance(to: 6)
        #expect(frames(writes).filter { $0 == "07/45" }.count == 3)
        flow.cancel()
        clock.advance(to: 20)
        #expect(frames(writes).filter { $0 == "07/45" }.count == 3, "cancel stops the retries")
    }
}
