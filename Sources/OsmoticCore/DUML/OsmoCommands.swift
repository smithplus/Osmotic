import Foundation

/// Builders for ready-to-write DUML frames on the BLE control channel (GATT `fff5`).
///
/// Receiver addressing is easy to get wrong and fails silently: addressed to the camera (`0x01`)
/// instead of their own subsystem, the session commands are answered `e0` and the camera never wakes.
/// See MEDIA_PROTOCOL.md §21–§25 in the upstream Osmosis repository.
public enum OsmoCommands {
    /// App(0x02) → WiFi(0x07).
    public static let targetAppToWifi = 0x0702
    /// App(0x02) → Camera(0x01).
    public static let targetAppToCamera = 0x0102
    /// App(0x02) → DM368(0x08).
    public static let targetAppToDM368 = 0x0802
    /// App(0x02) → session endpoint (type 0x10, id 7) = receiver byte `0xF0`.
    public static let targetAppToSession = 0xF002
    /// App(0x02) → type 0x1C, id 0.
    public static let targetAppTo1C = 0x1C02

    public static let pairMessageId = 0x8092
    public static let wifiMessageId = 0x8C19

    /// The app identity presented with SetPairingPIN, and the key a camera stores its approval under.
    /// This is the value moblin/dji-remote and Osmosis for Android use for cameras, so a camera that
    /// already approved one of those skips the on-screen prompt.
    public static let defaultIdentifier = "284ae5b8d76b3375a04a6417ad71bea3"

    /// The pairing token a camera expects. (Drones want "DJI FLY"; this app targets cameras.)
    public static let cameraPairingToken = "osmo"

    public static let sessionWake: [UInt8] = [0x04, 0x00]
    public static let sessionKeepalive: [UInt8] = [0x01, 0x01]

    /// `[len:u8][utf8]`.
    public static func packString(_ s: String) -> [UInt8] {
        let bytes = Array(s.utf8)
        return [UInt8(bytes.count & 0xFF)] + bytes
    }

    /// Generic request frame (`cmd_type 0x40`).
    public static func command(cmdSet: Int, cmdId: Int, payload: [UInt8] = [],
                               target: Int = targetAppToCamera, id: Int = 0x8000) -> [UInt8] {
        DjiMessage(target: target, id: id, type: 0x40 | (cmdSet << 8) | (cmdId << 16), payload: payload).encode()
    }

    /// SetPairingPIN (`0x07/0x45`): PackString(identifier) + PackString(pin).
    /// Reply `[00][status]`: `01` already paired, `02` approval required (then `0x07/0x46` arrives as a request).
    public static func setPairingPin(_ pin: String = cameraPairingToken, id: Int = pairMessageId,
                                     identifier: String = defaultIdentifier) -> [UInt8] {
        command(cmdSet: 0x07, cmdId: 0x45, payload: packString(identifier) + packString(pin),
                target: targetAppToWifi, id: id)
    }

    /// ConnectToWiFi (`0x07/0x47`) — only a fallback for bodies that never hand over credentials.
    public static func connectWifi(ssid: String, password: String, id: Int = wifiMessageId) -> [UInt8] {
        command(cmdSet: 0x07, cmdId: 0x47, payload: packString(ssid) + packString(password),
                target: targetAppToWifi, id: id)
    }

    /// Request to the WiFi subsystem: `0x07/0x07` SSID, `0x07/0x0e` passphrase, `0x07/0x0c` MAC.
    public static func wifiQuery(_ cmdId: Int, payload: [UInt8] = [], id: Int = 0x8000) -> [UInt8] {
        command(cmdSet: 0x07, cmdId: cmdId, payload: payload, target: targetAppToWifi, id: id)
    }

    /// `0x00/0x2b` to `0xF0`: `04 00` opens the session (before pairing), `01 01` is the keepalive.
    public static func sessionPing(_ payload: [UInt8], id: Int = 0x802B) -> [UInt8] {
        command(cmdSet: 0x00, cmdId: 0x2B, payload: payload, target: targetAppToSession, id: id)
    }

    /// `0x53/0x10 00000000` to `0x1C` — the frame that wakes a sleeping camera.
    public static func session5310(id: Int = 0x8053) -> [UInt8] {
        command(cmdSet: 0x53, cmdId: 0x10, payload: [0, 0, 0, 0], target: targetAppTo1C, id: id)
    }

    /// The "APP" device-info blob (62 bytes) used to answer the camera's `0x00/0x81` exchange and
    /// to register on the datalink.
    public static let appDeviceInfo: [UInt8] = {
        var b = [UInt8](repeating: 0, count: 62)
        b[1] = 0x41; b[2] = 0x50; b[3] = 0x50      // "APP"
        b[41] = 0x02; b[50] = 0x02; b[51] = 0x08
        return b
    }()

    /// Answer to an inbound request (flags `0x40`): swapped target, same id, flags `0xC0`, payload
    /// echoed (or the device-info blob for `0x00/0x81`). The camera drops the link if requests go
    /// unanswered.
    public static func response(to request: DjiMessage) -> [UInt8] {
        let swapped = ((request.target & 0xFF) << 8) | ((request.target >> 8) & 0xFF)
        let type = (request.type & 0xFFFF00) | 0xC0
        let payload = (request.cmdSet == 0x00 && request.cmdId == 0x81) ? appDeviceInfo : request.payload
        return DjiMessage(target: swapped, id: request.id, type: type, payload: payload).encode()
    }

    /// Parse a `[status:1][PackString]` reply (`0x07/0x07` SSID, `0x07/0x0e` password).
    public static func parseStatusPackString(_ p: [UInt8]) -> String? {
        guard p.count >= 2 else { return nil }
        let len = Int(p[1])
        guard 2 + len <= p.count else { return nil }
        return String(decoding: p[2..<(2 + len)], as: UTF8.self)
    }
}
