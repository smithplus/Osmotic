import Foundation
import OsmoticCore
import Security

/// A camera the user has connected to at least once.
struct SavedCamera: Codable, Hashable, Identifiable {
    /// CoreBluetooth's per-Mac peripheral identifier.
    var id: UUID
    var bleName: String
    var modelId: Int?
    var modelName: String
    var lastConnected: Date
}

/// User preferences, stored in `UserDefaults`.
enum Preferences {
    private static let d = UserDefaults.standard

    static var defaultDownloadFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent(
            "DJI", isDirectory: true)
    }

    static var downloadFolder: URL {
        get { d.string(forKey: "downloadFolder").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultDownloadFolder }
        set { d.set(newValue.path, forKey: "downloadFolder") }
    }

    static var organizeByDate: Bool {
        get { d.object(forKey: "organizeByDate") as? Bool ?? true }  // day folders unless turned off
        set { d.set(newValue, forKey: "organizeByDate") }
    }

    static var includeSidecars: Bool {
        get { d.object(forKey: "includeSidecars") as? Bool ?? true }
        set { d.set(newValue, forKey: "includeSidecars") }
    }

    static var restoreWifi: Bool {
        get { d.object(forKey: "restoreWifi") as? Bool ?? true }
        set { d.set(newValue, forKey: "restoreWifi") }
    }

    /// Sound (and a notification when the app is in the background) when a transfer finishes.
    static var notifyWhenDone: Bool {
        get { d.object(forKey: "notifyWhenDone") as? Bool ?? true }
        set { d.set(newValue, forKey: "notifyWhenDone") }
    }

    static var disconnectWhenDone: Bool {
        get { d.bool(forKey: "disconnectWhenDone") }
        set { d.set(newValue, forKey: "disconnectWhenDone") }
    }

    /// The network to return to, persisted so a crash mid-session can still be undone on next launch.
    static var pendingRestoreSSID: String? {
        get { d.string(forKey: "pendingRestoreSSID") }
        set { d.set(newValue, forKey: "pendingRestoreSSID") }
    }

    /// The Mac's address on the camera's network during the pending session: without Location
    /// permission it's how a relaunch tells "still on the camera" from a home router at 192.168.2.1.
    static var pendingCameraSideIP: String? {
        get { d.string(forKey: "pendingCameraSideIP") }
        set { d.set(newValue, forKey: "pendingCameraSideIP") }
    }

    /// Whether the pending camera network was added by this app (and so may be forgotten).
    static var pendingForgetCamera: Bool {
        get { d.object(forKey: "pendingForgetCamera") as? Bool ?? true }
        set { d.set(newValue, forKey: "pendingForgetCamera") }
    }

    static var pendingCameraSSID: String? {
        get { d.string(forKey: "pendingCameraSSID") }
        set { d.set(newValue, forKey: "pendingCameraSSID") }
    }
}

enum SavedCameraStore {
    private static let key = "savedCameras"

    static func all() -> [SavedCamera] {
        guard let data = UserDefaults.standard.data(forKey: key),
            let list = try? JSONDecoder().decode([SavedCamera].self, from: data)
        else { return [] }
        return list.sorted { $0.lastConnected > $1.lastConnected }
    }

    static func save(_ camera: SavedCamera) {
        var list = all().filter { $0.id != camera.id }
        list.append(camera)
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: key) }
    }

    static func remove(_ id: UUID) {
        let list = all().filter { $0.id != id }
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: key) }
        Keychain.delete(account: id.uuidString)
    }

    /// The camera's own AP passphrase — the one its settings screen shows. The camera normally hands it
    /// over BLE on every connect; this copy (in the Keychain) is only the fallback for when it doesn't.
    static func password(for id: UUID) -> String? {
        Keychain.read(account: id.uuidString)
    }

    static func setPassword(_ password: String, for id: UUID) {
        Keychain.write(password, account: id.uuidString)
    }

    /// Earlier builds kept the passphrase in UserDefaults, in plain text: move it to the Keychain.
    static func migratePasswordsToKeychain() {
        let d = UserDefaults.standard
        for key in d.dictionaryRepresentation().keys where key.hasPrefix("wifiPassword.") {
            if let value = d.string(forKey: key) {
                Keychain.write(value, account: String(key.dropFirst("wifiPassword.".count)))
            }
            d.removeObject(forKey: key)
        }
    }
}

/// Generic-password items under one service name, one account per saved camera.
enum Keychain {
    private static let service = "io.github.smithplus.osmotic.camera-wifi"

    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func read(account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, account: String) {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(account)
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            SecItemAdd(q as CFDictionary, nil)
        }
    }

    static func delete(account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}

/// Every file already transferred, so "new" survives the user moving files out of the folder.
final class DownloadHistory {
    private var keys: Set<String>
    private let url: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Osmotic", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("downloaded.json")
        keys = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Set<String>.self, from: $0) } ?? []
    }

    static func key(_ f: CameraFile) -> String { "\(f.name)|\(f.sizeBytes)" }

    func contains(_ f: CameraFile) -> Bool { keys.contains(Self.key(f)) }

    func insert(_ f: CameraFile) {
        keys.insert(Self.key(f))
        if let data = try? JSONEncoder().encode(keys) { try? data.write(to: url, options: .atomic) }
    }

    func clear() {
        keys.removeAll()
        try? FileManager.default.removeItem(at: url)
    }
}

enum DownloadPaths {
    /// Where a file lands: the download folder, optionally inside a `YYYY-MM-DD` subfolder.
    static func destination(
        for f: CameraFile, root: URL = Preferences.downloadFolder,
        byDate: Bool = Preferences.organizeByDate
    ) -> URL {
        var dir = root
        // `YYYY-MM-DD` straight from the name's stamp (the camera's local date): no formatter per call —
        // this runs for every file whenever the history is refreshed.
        let t = Array(f.timestamp.utf8)
        if byDate, t.count == 14 {
            let day =
                String(decoding: t[0..<4], as: UTF8.self) + "-" + String(decoding: t[4..<6], as: UTF8.self) + "-"
                + String(decoding: t[6..<8], as: UTF8.self)
            dir = dir.appendingPathComponent(day, isDirectory: true)
        }
        return dir.appendingPathComponent(f.localName)
    }
}
