import CoreBluetooth
import Foundation
import Observation
import OsmoticCore

/// A DJI camera seen in a BLE scan.
struct DiscoveredCamera: Identifiable, Hashable {
    let id: UUID
    var name: String
    var rssi: Int
    var modelId: Int?
    var model: CameraModel
    var brand: Brand
    var lastSeen: Date

    static func == (a: Self, b: Self) -> Bool { a.id == b.id && a.name == b.name && a.rssi == b.rssi && a.modelId == b.modelId }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// CoreBluetooth front end: finds Osmo cameras and brings up their DUML control channel.
///
/// GATT setup the camera requires before it acts on anything (MEDIA_PROTOCOL.md): notifications on
/// **both** `fff4` and `fff5`, then `01 00` written to the `fff4` value with response, a ~200 ms settle,
/// and only then `fff5` traffic (write-without-response, spaced).
@Observable
final class BluetoothService: NSObject {
    enum Power { case unknown, poweredOn, poweredOff, unauthorized, unsupported }

    private(set) var power: Power = .unknown
    private(set) var isScanning = false
    private(set) var cameras: [UUID: DiscoveredCamera] = [:]

    /// The control channel is armed and ready for DUML frames.
    var onReady: (() -> Void)?
    var onMessage: ((DjiMessage) -> Void)?
    var onDisconnect: ((Error?) -> Void)?

    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var fff4: CBCharacteristic?
    @ObservationIgnored private var fff5: CBCharacteristic?
    @ObservationIgnored private var notifyPending: Set<CBUUID> = []
    @ObservationIgnored private var accumulator = DumlFrameAccumulator()
    @ObservationIgnored private var writeQueue: [[UInt8]] = []
    @ObservationIgnored private var writing = false
    @ObservationIgnored private var armed = false
    @ObservationIgnored private var wantScan = false
    @ObservationIgnored private var others = 0

    private static let service = CBUUID(string: BleConstants.serviceFFF0)
    private static let char4 = CBUUID(string: BleConstants.charFFF4)
    private static let char5 = CBUUID(string: BleConstants.charFFF5)
    /// Minimum spacing between `fff5` writes — back-to-back write-without-response frames get dropped.
    private static let writeSpacing: Duration = .milliseconds(60)

    override init() {
        super.init()
    }

    /// Created on first use, so merely launching the app (e.g. in demo mode) never prompts for Bluetooth.
    private func ensureCentral() {
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
    }

    /// Demo/snapshot only: show a camera without any radio.
    func injectDemo(_ camera: DiscoveredCamera) { cameras[camera.id] = camera }

    var sortedCameras: [DiscoveredCamera] { cameras.values.sorted { $0.rssi > $1.rssi } }

    // ---- scanning -------------------------------------------------------------------------------

    func startScan() {
        wantScan = true
        ensureCentral()
        guard central.state == .poweredOn, !isScanning else { return }
        others = 0
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        isScanning = true
        log("BLE: scan started")
    }

    func stopScan() {
        wantScan = false
        guard isScanning, let central else { return }
        central.stopScan()
        isScanning = false
        log("BLE: scan stopped (\(others) other devices seen, not logged)")
    }

    /// Drop cameras not heard from recently, so the list reflects what's in range.
    func pruneStale(olderThan seconds: TimeInterval = 12) {
        let cutoff = Date().addingTimeInterval(-seconds)
        for (id, cam) in cameras where cam.lastSeen < cutoff && id != peripheral?.identifier { cameras[id] = nil }
    }

    // ---- connection -----------------------------------------------------------------------------

    /// Connect to a camera seen in the scan, or a saved one by identifier.
    func connect(_ id: UUID) -> Bool {
        disconnect()
        ensureCentral()
        guard let p = central.retrievePeripherals(withIdentifiers: [id]).first else {
            log("BLE: peripheral \(id) not known to CoreBluetooth")
            return false
        }
        peripheral = p
        p.delegate = self
        accumulator = DumlFrameAccumulator()
        writeQueue.removeAll()
        armed = false
        log("BLE: connecting to \(p.name ?? id.uuidString)…")
        central.connect(p, options: nil)
        return true
    }

    func disconnect() {
        if let p = peripheral {
            p.delegate = nil
            central?.cancelPeripheralConnection(p)
        }
        peripheral = nil
        fff4 = nil
        fff5 = nil
        armed = false
        writeQueue.removeAll()
    }

    var isConnected: Bool { peripheral?.state == .connected }

    /// Queue a DUML frame for `fff5`; writes go out spaced by `writeSpacing`.
    func write(_ frame: [UInt8]) {
        guard armed else { log("BLE: dropped a write before the channel was armed"); return }
        writeQueue.append(frame)
        pumpWrites()
    }

    private func pumpWrites() {
        guard !writing, !writeQueue.isEmpty, let p = peripheral, let c = fff5 else { return }
        guard p.canSendWriteWithoutResponse else { return }  // resumed by peripheralIsReady
        writing = true
        let frame = writeQueue.removeFirst()
        p.writeValue(Data(frame), for: c, type: .withoutResponse)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.writeSpacing)
            self?.writing = false
            self?.pumpWrites()
        }
    }

    private func arm(_ p: CBPeripheral) {
        guard let c4 = fff4 else { finishArming(); return }
        // The camera acts on nothing until this lands.
        let type: CBCharacteristicWriteType = c4.properties.contains(.write) ? .withResponse : .withoutResponse
        log("BLE: writing [01 00] to fff4 (\(type == .withResponse ? "with" : "without") response)")
        p.writeValue(Data([0x01, 0x00]), for: c4, type: type)
        if type == .withoutResponse { finishArming() }
    }

    private func finishArming() {
        guard !armed else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, self.peripheral != nil else { return }
            self.armed = true
            let mtu = self.peripheral?.maximumWriteValueLength(for: .withoutResponse) ?? 0
            log("BLE: control channel armed (max write \(mtu) B)")
            self.onReady?()
        }
    }
}

extension BluetoothService: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: power = .poweredOn
        case .poweredOff: power = .poweredOff
        case .unauthorized: power = .unauthorized
        case .unsupported: power = .unsupported
        default: power = .unknown
        }
        log("BLE: state \(central.state.rawValue)")
        if central.state == .poweredOn {
            if wantScan { isScanning = false; startScan() }
        } else {
            isScanning = false
        }
    }

    // `RSSI` is the name CBCentralManagerDelegate gives this parameter.
    // swift-format-ignore: AlwaysUseLowerCamelCase
    func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        var modelId: Int?
        var payload: [UInt8]?
        var djiCid = false
        if let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
            let split = BleAdvert.splitManufacturerData([UInt8](data)), BleConstants.isDjiCompanyId(split.companyId)
        {
            djiCid = true
            payload = split.payload
            modelId = BleAdvert.modelId(split.payload)
        }
        let brand = Brand.of(name: name, manufacturerPayload: payload, djiCompanyId: djiCid)
        guard brand != .unknown || modelId != nil else { others += 1; return }
        let model = CameraModel.resolve(modelId: modelId, name: name, brand: brand)
        guard !model.isDrone else { return }  // this app offloads cameras only
        let id = peripheral.identifier
        let rssi = RSSI.intValue == 127 ? (cameras[id]?.rssi ?? -80) : RSSI.intValue
        if cameras[id] == nil {
            log("BLE: found \(name ?? "?") model=\(model.name)\(payload.map { " mfr=\($0.hexString)" } ?? "") rssi=\(rssi)")
        }
        cameras[id] = DiscoveredCamera(
            id: id, name: name ?? cameras[id]?.name ?? model.name, rssi: rssi,
            modelId: modelId ?? cameras[id]?.modelId, model: model, brand: brand, lastSeen: Date())
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("BLE: connected; discovering fff0")
        peripheral.discoverServices([Self.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("BLE: connect failed: \(error?.localizedDescription ?? "?")")
        guard peripheral == self.peripheral else { return }
        self.peripheral = nil
        onDisconnect?(error)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log("BLE: disconnected\(error.map { " (\($0.localizedDescription))" } ?? "")")
        guard peripheral == self.peripheral else { return }
        self.peripheral = nil
        armed = false
        onDisconnect?(error)
    }
}

extension BluetoothService: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
            log(
                "BLE: service fff0 NOT found (present: \(peripheral.services?.map(\.uuid.uuidString).joined(separator: ",") ?? "none"))"
            )
            return
        }
        peripheral.discoverCharacteristics([Self.char4, Self.char5], for: svc)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let chars = service.characteristics ?? []
        log(
            "BLE: fff0 characteristics: "
                + chars.map { "\($0.uuid.uuidString)(0x\(String($0.properties.rawValue, radix: 16)))" }.joined(separator: " "))
        fff4 = chars.first { $0.uuid == Self.char4 }
        fff5 = chars.first { $0.uuid == Self.char5 }
        guard fff5 != nil else { log("BLE: fff5 missing — cannot talk to this camera"); return }
        notifyPending = []
        for c in [fff4, fff5].compactMap({ $0 }) where c.properties.contains(.notify) || c.properties.contains(.indicate) {
            notifyPending.insert(c.uuid)
            peripheral.setNotifyValue(true, for: c)
        }
        if notifyPending.isEmpty { arm(peripheral) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        log(
            "BLE: notify on \(characteristic.uuid.uuidString) = \(characteristic.isNotifying)\(error.map { " error \($0.localizedDescription)" } ?? "")"
        )
        notifyPending.remove(characteristic.uuid)
        if notifyPending.isEmpty { arm(peripheral) }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.uuid == Self.char4 {
            log("BLE: fff4 arm write complete\(error.map { " (error \($0.localizedDescription))" } ?? "")")
            finishArming()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        for m in accumulator.append([UInt8](data)) { onMessage?(m) }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        pumpWrites()
    }
}
