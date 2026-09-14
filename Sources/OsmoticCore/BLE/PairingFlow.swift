import Foundation

/// The BLE control-channel conversation that takes a camera from "connected" to "here is my Wi-Fi",
/// in the order and spacing of the official app's HCI trace (via Osmosis):
///
/// ```
/// 0x00/0x2b 04 00  → 0xF0        open the session (before pairing)
/// 0x07/0x45        SetPairingPIN → 01 already paired | 02 approve on camera, then 0x07/0x46 request
/// 0x53/0x10        → 0x1C         wake (a Pocket 3 answers e0; its AP comes up anyway)
/// 0x07/0x07        GetWifiSsid
/// 0x07/0x0e        GetWifiPassword
/// ```
///
/// Every inbound request (flags `0x40`) is answered, or the camera drops the link. `fff5` is
/// write-without-response, so writes are paced by the caller's scheduler rather than sent back to back.
public final class PairingFlow {
    public enum Event: Equatable, Sendable {
        case approvalRequired
        case paired
        case credentials(ssid: String, password: String)
        case needsPassword(ssid: String)
        case notActivated
    }

    public var write: ([UInt8]) -> Void = { _ in }
    public var emit: (Event) -> Void = { _ in }
    public var log: (String) -> Void = { _ in }
    /// Run a closure after a delay (the app wires this to the main actor).
    public var schedule: (TimeInterval, @escaping () -> Void) -> Void = { _, f in f() }

    public private(set) var ssid: String
    /// Read only if the camera doesn't hand its password over BLE (it lives in the Keychain).
    private let savedPassword: () -> String?
    private let identifier: String
    private var generation = 0
    private var pairReplyStatus: Int?
    private var approvalShown = false
    private var credsRequested = false
    private var delivered = false
    private var password: String?
    private var ssidKnown = false
    private var activationState = -1

    public init(
        bleName: String, savedPassword: @autoclosure @escaping () -> String?,
        identifier: String = OsmoCommands.defaultIdentifier
    ) {
        self.ssid = bleName
        self.savedPassword = savedPassword
        self.identifier = identifier
    }

    /// Stop acting on any pending timers (disconnect / cancel).
    public func cancel() { generation += 1 }

    private func after(_ delay: TimeInterval, _ body: @escaping () -> Void) {
        let gen = generation
        schedule(delay) { [weak self] in
            guard let self, self.generation == gen else { return }
            body()
        }
    }

    /// GATT is armed (notifications on, `01 00` written to fff4).
    public func onReady() {
        write(OsmoCommands.sessionPing(OsmoCommands.sessionWake))
        log("BLE: sent session wake 0x00/0x2b [04 00]")
        after(0.12) { [self] in
            write(OsmoCommands.setPairingPin(identifier: identifier))
            log("BLE: sent SetPairingPIN (token \"osmo\")")
        }
        for delay in [2.5, 5.0, 8.0] {
            after(delay) { [self] in
                guard pairReplyStatus == nil, !credsRequested else { return }
                log("BLE: no pairing reply yet — re-sending SetPairingPIN")
                write(OsmoCommands.setPairingPin(identifier: identifier))
            }
        }
    }

    public func onMessage(_ m: DjiMessage) {
        if m.flags == 0x40 {
            write(OsmoCommands.response(to: m))
            if m.cmdSet == 0x07 && m.cmdId == 0x46 {
                log("BLE: pairing approved on the camera (0x07/0x46)")
                onPaired()
            } else {
                log(String(format: "BLE: answered request 0x%02x/%02x", m.cmdSet, m.cmdId))
            }
            return
        }
        if m.cmdSet == 0x07 {
            let p = m.payload
            switch m.cmdId {
            case 0x45:
                let status = p.count >= 2 ? Int(p[1]) : -1
                if pairReplyStatus != status {
                    log(
                        String(
                            format: "BLE: pairing reply 0x%02x (%@)", status,
                            status == 1 ? "already paired" : status == 2 ? "approval required" : "?"))
                }
                pairReplyStatus = status
                if status == 0x02 && !approvalShown {
                    approvalShown = true
                    emit(.approvalRequired)
                }
                if status == 0x01 { onPaired() }
            case 0x46:
                log("BLE: pairing approved (0x07/0x46)")
                onPaired()
            case 0x07:
                if let s = OsmoCommands.parseStatusPackString(p), !s.isEmpty {
                    ssid = s
                    ssidKnown = true
                    log("BLE: camera Wi-Fi SSID = \"\(s)\"")
                    if let password { deliver(password) }
                }
            case 0x0E:
                if let pass = OsmoCommands.parseStatusPackString(p), !pass.isEmpty {
                    password = pass
                    log("BLE: Wi-Fi password received over BLE (\(pass.count) chars)")
                    if ssidKnown {
                        deliver(pass)
                    } else {
                        // The SSID reply went missing: ask again, and fall back to the BLE name
                        // (the AP is normally named after it) only if it still doesn't come.
                        write(OsmoCommands.wifiQuery(0x07, id: 0x8007))
                        after(2.0) { [self] in
                            if !delivered { log("BLE: no SSID reply — using the Bluetooth name \"\(ssid)\"") }
                            deliver(pass)
                        }
                    }
                } else {
                    log("BLE: 0x07/0x0e reply carried no password")
                }
            case 0x47:
                log("BLE: ConnectToWiFi result [\(p.hexString)]")
            default:
                break
            }
            return
        }
        if m.cmdSet == 0x00 && m.cmdId == 0x32 {
            let p = m.payload
            if p.count >= 21 && p[0] == 0x33 && p[1] == 0x33 {
                let st = Int(p[20])
                if st != activationState {
                    activationState = st
                    log("BLE: activation state \(st)")
                }
            }
        }
    }

    /// Camera never activated with DJI's servers keeps its Wi-Fi off.
    public var saysNotActivated: Bool { activationState == 0 || activationState == 2 }

    private func onPaired() {
        guard !credsRequested else { return }
        credsRequested = true
        emit(.paired)
        after(0.1) { [self] in
            write(OsmoCommands.session5310()); log("BLE: sent 0x53/0x10 (wake)")
        }
        after(0.9) { [self] in write(OsmoCommands.wifiQuery(0x07, id: 0x8007)) }
        after(1.4) { [self] in write(OsmoCommands.wifiQuery(0x0E, id: 0x800E)) }
        // Reads are idempotent: ask once more in case a write-without-response was dropped.
        after(3.2) { [self] in if !ssidKnown { write(OsmoCommands.wifiQuery(0x07, id: 0x8007)) } }
        after(3.7) { [self] in if password == nil { write(OsmoCommands.wifiQuery(0x0E, id: 0x800E)) } }
        after(6.0) { [self] in
            guard !delivered else { return }
            if saysNotActivated {
                emit(.notActivated)
            } else if let saved = savedPassword(), !saved.isEmpty {
                log("BLE: no credentials over BLE — using the saved password")
                deliver(saved)
            } else {
                emit(.needsPassword(ssid: ssid))
            }
        }
    }

    private func deliver(_ pass: String) {
        guard !delivered else { return }
        delivered = true
        emit(.credentials(ssid: ssid, password: pass))
    }

    /// The user typed the password after `.needsPassword`.
    public func providePassword(_ pass: String) { deliver(pass) }
}
