import Foundation

public enum BleConstants {
    public static let serviceFFF0 = "FFF0"
    public static let charFFF4 = "FFF4"
    public static let charFFF5 = "FFF5"

    /// DJI BLE manufacturer company ids (little-endian on the wire: `AA 08`, `AA F7`, `C0 E5`).
    public static let djiCompanyId = 0x08AA
    public static let djiCompanyIdAlt = 0xF7AA
    public static let djiCompanyIdE5C0 = 0xE5C0

    public static func isDjiCompanyId(_ cid: Int) -> Bool {
        cid == djiCompanyId || cid == djiCompanyIdAlt || cid == djiCompanyIdE5C0
    }

    public static let modelNames: [Int: String] = [
        0x0006: "OsmoAction", 0x0010: "OsmoAction2", 0x0012: "OsmoAction3", 0x0014: "OsmoAction4",
        0x0015: "OsmoAction5Pro", 0x0017: "Osmo360", 0x0018: "OsmoAction6", 0x0019: "OsmoNano",
        0x0020: "OsmoPocket3", 0x0021: "OsmoPocket4", 0x0022: "OsmoPocket4Pro",
        0x0070: "Mavic3", 0x007e: "Neo2",
    ]
}

/// Decodes the model id out of a DJI advertisement's manufacturer payload (company id stripped).
///
/// Two formats exist: the classic u16-LE model id at `[0:2]`, and a newer one (Pocket 4 Pro) where bit 2
/// of byte 5 flags a 16-bit product type at `[10:12]`.
public enum BleAdvert {
    public struct Decoded: Sendable, Equatable {
        public let modelId: Int?
        public let newFormat: Bool
        public let rawProductType: Int?
    }

    private static let productTypeToModelId: [Int: Int] = [
        40: 0x0006, 143: 0x0010, 231: 0x0012, 203: 0x0014, 235: 0x0015, 224: 0x0017,
        223: 0x0018, 222: 0x0019, 145: 0x0020, 219: 0x0021, 218: 0x0022, 229: 0x0087,
    ]

    public static func decode(_ payload: [UInt8]) -> Decoded {
        if let pt = productType(payload) {
            let mapped = productTypeToModelId[pt]
            if mapped != nil || legacyModelId(payload) == nil {
                return Decoded(modelId: mapped, newFormat: true, rawProductType: pt)
            }
            return Decoded(modelId: legacyModelId(payload), newFormat: false, rawProductType: pt)
        }
        return Decoded(modelId: legacyModelId(payload), newFormat: false, rawProductType: nil)
    }

    public static func modelId(_ payload: [UInt8]) -> Int? { decode(payload).modelId }

    private static func productType(_ p: [UInt8]) -> Int? {
        guard p.count > 5, p[5] & 0x04 != 0, p.count >= 12 else { return nil }
        return Int(p[10]) | (Int(p[11]) << 8)
    }

    private static func legacyModelId(_ p: [UInt8]) -> Int? {
        guard p.count >= 2 else { return nil }
        let id = Int(p[0]) | (Int(p[1]) << 8)
        return id == 0 ? nil : id
    }

    /// Split CoreBluetooth's `kCBAdvDataManufacturerData` (company id first, LE) into id + payload.
    public static func splitManufacturerData(_ data: [UInt8]) -> (companyId: Int, payload: [UInt8])? {
        guard data.count >= 2 else { return nil }
        return (Int(data[0]) | (Int(data[1]) << 8), Array(data.dropFirst(2)))
    }
}

/// Camera brand. Xtra is a DJI rebrand that runs a different datalink port.
public enum Brand: String, Sendable {
    case dji, xtra, unknown

    static let xtraOUI: [UInt8] = [0xEC, 0x9E, 0xEA]

    /// macOS never exposes a peripheral's MAC, so the Xtra OUI is read from the advertised MAC that
    /// classic-format payloads carry at `[3:9]`, when present; the name and DJI company id do the rest.
    public static func of(name: String?, manufacturerPayload: [UInt8]?, djiCompanyId: Bool) -> Brand {
        let n = name?.lowercased() ?? ""
        if let p = manufacturerPayload, p.count >= 9, Array(p[3..<6]) == xtraOUI { return .xtra }
        if n.contains("xtra") || n.contains("edge") { return .xtra }
        if djiCompanyId { return .dji }
        if ["osmo", "nano", "dji", "pocket", "action"].contains(where: n.contains) { return .dji }
        return .unknown
    }
}

/// Per-model datalink capabilities. Only the UDP port, the TCP-7001 poke and WiFi security vary across
/// the Osmo line; pairing, the `/v2` media API and the manifest format are shared.
public struct CameraModel: Sendable, Equatable {
    public var name: String
    public var datalinkPort: UInt16 = 9004
    public var tcpPoke = true
    public var wpa3 = false
    public var verified = false
    /// The Pocket 3 has exactly one store, its microSD, always served at `/v2?storage=0`.
    public var singleSdStorage = false
    public var isDrone = false

    public init(
        name: String, datalinkPort: UInt16 = 9004, tcpPoke: Bool = true, wpa3: Bool = false,
        verified: Bool = false, singleSdStorage: Bool = false, isDrone: Bool = false
    ) {
        self.name = name
        self.datalinkPort = datalinkPort
        self.tcpPoke = tcpPoke
        self.wpa3 = wpa3
        self.verified = verified
        self.singleSdStorage = singleSdStorage
        self.isDrone = isDrone
    }

    /// The other datalink config to try when the handshake never lands.
    public func alternate() -> CameraModel {
        var m = self
        m.verified = false
        if datalinkPort == 9004 { m.datalinkPort = 10004; m.tcpPoke = false } else { m.datalinkPort = 9004; m.tcpPoke = true }
        return m
    }

    public static let `default` = CameraModel(name: "Cámara DJI Osmo")
    public static let idPocket3 = 0x0020

    static let byId: [Int: CameraModel] = [
        0x0010: CameraModel(name: "Osmo Action 2"),
        0x0012: CameraModel(name: "Osmo Action 3"),
        0x0014: CameraModel(name: "Osmo Action 4", verified: true),
        0x0015: CameraModel(name: "Osmo Action 5 Pro", verified: true),
        0x0017: CameraModel(name: "Osmo 360", wpa3: true),
        0x0018: CameraModel(name: "Osmo Action 6", verified: true),
        0x0019: CameraModel(name: "Osmo Nano", verified: true),
        0x0020: CameraModel(name: "Osmo Pocket 3", verified: true, singleSdStorage: true),
        0x0021: CameraModel(name: "Osmo Pocket 4", verified: true),
        0x0022: CameraModel(name: "Osmo Pocket 4 Pro", verified: true),
        0x0070: CameraModel(name: "Mavic 3", datalinkPort: 9003, tcpPoke: false, verified: true, isDrone: true),
        0x007e: CameraModel(name: "DJI Neo 2", datalinkPort: 9003, tcpPoke: false, isDrone: true),
    ]

    static let xtraNames: [Int: String] = [
        0x0019: "Xtra Atto", 0x0014: "Xtra Edge", 0x0015: "Xtra Edge Pro", 0x0020: "Xtra Muse",
    ]

    /// Resolve by BLE model id, then by local name, then adjust for brand (every Xtra runs 10004/no poke).
    public static func resolve(modelId: Int?, name: String?, brand: Brand = .unknown) -> CameraModel {
        let base = byIdOrName(modelId, name)
        guard brand == .xtra else { return base }
        let isEdgePro = modelId == 0x0015 || base.name.contains("Action 5")
        var m = base
        m.name = modelId.flatMap { xtraNames[$0] } ?? (isEdgePro ? "Xtra Edge Pro" : "Xtra \(base.name)")
        m.datalinkPort = 10004
        m.tcpPoke = false
        m.verified = isEdgePro
        return m
    }

    private static let droneIdFloor = 0x0040

    private static func byIdOrName(_ modelId: Int?, _ name: String?) -> CameraModel {
        if let modelId, let m = byId[modelId] { return m }
        if let modelId, modelId >= droneIdFloor {
            let label = (name?.isEmpty == false) ? "Dron DJI (\(name!))" : "Dron DJI"
            return CameraModel(name: label, datalinkPort: 9003, tcpPoke: false, isDrone: true)
        }
        let n = (name ?? "").lowercased().replacingOccurrences(of: " ", with: "")
        func id(_ v: Int) -> CameraModel { byId[v]! }
        if n.contains("pocket3") || n.contains("muse") { return id(0x0020) }
        if n.contains("pocket4p") { return id(0x0022) }
        if n.contains("pocket4") { return id(0x0021) }
        if n.contains("360") { return id(0x0017) }
        if n.contains("nano") || n.contains("atto") { return id(0x0019) }
        if n.contains("action6") { return id(0x0018) }
        if n.contains("action5") || n.contains("edgepro") { return id(0x0015) }
        if n.contains("action4") || n.contains("edge") { return id(0x0014) }
        if n.contains("action3") { return id(0x0012) }
        if n.contains("action2") { return id(0x0010) }
        var d = CameraModel.default
        if let name, !name.isEmpty { d.name = name }
        return d
    }
}
