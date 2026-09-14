import Foundation
import OsmoticCore

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
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("DJI", isDirectory: true)
    }

    static var downloadFolder: URL {
        get { d.string(forKey: "downloadFolder").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultDownloadFolder }
        set { d.set(newValue.path, forKey: "downloadFolder") }
    }

    static var organizeByDate: Bool {
        get { d.bool(forKey: "organizeByDate") }
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

    static var pendingCameraSSID: String? {
        get { d.string(forKey: "pendingCameraSSID") }
        set { d.set(newValue, forKey: "pendingCameraSSID") }
    }
}

enum SavedCameraStore {
    private static let key = "savedCameras"

    static func all() -> [SavedCamera] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([SavedCamera].self, from: data) else { return [] }
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
        UserDefaults.standard.removeObject(forKey: "wifiPassword.\(id.uuidString)")
    }

    /// The camera's own AP passphrase — the one its settings screen shows. The camera normally hands it
    /// over BLE on every connect; this copy is only the fallback for when it doesn't.
    static func password(for id: UUID) -> String? {
        UserDefaults.standard.string(forKey: "wifiPassword.\(id.uuidString)")
    }

    static func setPassword(_ password: String, for id: UUID) {
        UserDefaults.standard.set(password, forKey: "wifiPassword.\(id.uuidString)")
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
    static func destination(for f: CameraFile, root: URL = Preferences.downloadFolder,
                            byDate: Bool = Preferences.organizeByDate) -> URL {
        var dir = root
        if byDate, let date = f.captureDate {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            fmt.locale = Locale(identifier: "en_US_POSIX")
            dir = dir.appendingPathComponent(fmt.string(from: date), isDirectory: true)
        }
        return dir.appendingPathComponent(f.name)
    }
}
