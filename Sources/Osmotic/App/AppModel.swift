import AppKit
import Foundation
import Observation
import OsmoticCore
import SwiftUI
import UserNotifications

/// The app's single source of truth: which screen is up, the connection in progress, the camera's
/// library, and the transfer queue.
///
/// Split by area into `AppModel+Connection`, `+Teardown`, `+Library`, `+Transfers`, `+Live` and
/// `+Demo`. Stored properties can only live here, and those extensions write them, so their setters
/// are internal rather than `private(set)` (Swift's `private` ends at the file).
@Observable
final class AppModel {
    enum Screen { case cameras, connecting, library }

    enum Stage: Int, CaseIterable, Comparable {
        case bluetooth, pairing, wifi, datalink, library
        static func < (a: Stage, b: Stage) -> Bool { a.rawValue < b.rawValue }

        var title: String {
            switch self {
            case .bluetooth: String(localized: "Bluetooth")
            case .pairing: String(localized: "Pairing")
            case .wifi: String(localized: "Camera Wi-Fi")
            case .datalink: String(localized: "Camera link")
            case .library: String(localized: "Library")
            }
        }
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all, videos, photos, favorites, new
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .all: "All"
            case .videos: "Videos"
            case .photos: "Photos"
            case .favorites: "Starred"
            case .new: "New"
            }
        }
    }

    struct Target: Equatable {
        let id: UUID
        let name: String
        let model: CameraModel
        let modelId: Int?
    }

    struct TransferState {
        var total: Int
        var done = 0
        var failed: [String] = []
        var current: CameraFile?
        var currentBytes = 0
        var currentSize = 0
        var bytesTotal: Int
        var bytesDone = 0
        var speed: Double = 0  // bytes/s, smoothed
        var started = Date()

        var fraction: Double {
            guard bytesTotal > 0 else { return total > 0 ? Double(done) / Double(total) : 0 }
            return min(1, Double(bytesDone + currentBytes) / Double(bytesTotal))
        }

        var eta: TimeInterval? {
            guard speed > 1, bytesTotal > 0 else { return nil }
            return Double(bytesTotal - bytesDone - currentBytes) / speed
        }
    }

    // ---- connection ---------------------------------------------------------------------------
    var screen: Screen = .cameras
    var stage: Stage = .bluetooth
    var stageDetail = ""
    var datalinkProgress = 0.0
    var target: Target?
    var needsApproval = false
    var passwordPromptSSID: String?
    var connectError: String?
    var linkLost = false
    /// Returning the Wi-Fi is in progress (shown on the cameras screen).
    var restoringWifi = false
    /// The automatic return to the user's network failed; they have to pick one in the menu bar.
    var wifiRestoreFailed = false

    // ---- library ------------------------------------------------------------------------------
    var files: [CameraFile] = []
    var status = CameraStatus()
    var moreAvailable = false
    var loadingMore = false
    var selection: Set<String> = []
    var filter: Filter = .all
    var downloaded: Set<String> = []
    var previewFile: CameraFile?
    /// Sizes the camera's web server stated, by file id. The manifest's size is a u32 that wraps
    /// above 4 GiB, so a long 4K clip can be listed as a few hundred MB — or as nothing.
    var realSizes: [String: Int] = [:]
    @ObservationIgnored var sizeProbed: Set<String> = []
    @ObservationIgnored var selectionAnchor: String?
    /// The keyboard's place in the grid (arrow keys move it; it gets a focus outline).
    var cursor: String?

    // ---- transfers ----------------------------------------------------------------------------
    var transfer: TransferState? {
        didSet { if (transfer != nil) != isTransferring { isTransferring = transfer != nil } }
    }
    /// Whether a transfer runs, for views that don't need its progress (it changes many times a second).
    private(set) var isTransferring = false
    struct TransferSummary: Equatable {
        let ok: Bool
        let text: String
    }
    var lastTransferSummary: TransferSummary?
    /// Files waiting in the transfer queue or downloading now. Stored (not derived from `transfer`) so
    /// the grid's cells don't re-render on every progress tick.
    var queuedIds: Set<String> = []
    /// The file downloading right now (only its cell follows the progress).
    var currentTransferId: String?
    /// Shows the "cancel the download?" confirmation first when files are still coming in.
    var confirmingDisconnect = false
    @ObservationIgnored var speedSample = (time: Date(), bytes: 0)
    @ObservationIgnored var retryCounts: [String: Int] = [:]

    let ble = BluetoothService()
    let http = CameraHTTP()
    @ObservationIgnored private(set) lazy var thumbnails = ThumbnailFetcher(http: http, cacheDir: Self.thumbnailCacheDir)
    @ObservationIgnored lazy var downloader = FileDownloader(http: http, log: { log($0) })
    @ObservationIgnored let history = DownloadHistory()
    @ObservationIgnored let location = LocationPermission()
    @ObservationIgnored var flow: PairingFlow?
    @ObservationIgnored var session: CameraSession?
    @ObservationIgnored var connectTask: Task<Void, Never>?
    @ObservationIgnored var transferTask: Task<Void, Never>?
    @ObservationIgnored var queue: [CameraFile] = []
    @ObservationIgnored var credentials: CheckedContinuation<(ssid: String, password: String), Error>?
    @ObservationIgnored var armed: CheckedContinuation<Void, Error>?
    @ObservationIgnored var isArmed = false
    @ObservationIgnored var pendingCredentials: (ssid: String, password: String)?
    @ObservationIgnored var previousSSID: String?
    @ObservationIgnored var joinedCameraSSID: String?
    /// False when the camera's network was already among the Mac's saved networks before we joined.
    @ObservationIgnored var forgetCameraNetwork = true
    /// Decoded thumbnails, bounded (~150 MB): a big card scrolled end to end must not keep them all.
    @ObservationIgnored let thumbCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.totalCostLimit = 150 << 20
        return c
    }()

    func cacheThumbnail(_ image: NSImage, for id: String) {
        let px = image.representations.first.map { $0.pixelsWide * $0.pixelsHigh } ?? 0
        thumbCache.setObject(image, forKey: id as NSString, cost: max(1, px * 4))
    }
    @ObservationIgnored var connectGeneration = 0
    @ObservationIgnored var cameraPassword: String?
    @ObservationIgnored var recovering = false
    @ObservationIgnored var cameraSideIP: String?
    @ObservationIgnored var transferGeneration = 0
    var reconnecting = false
    /// Link recovery ran out of attempts: the library offers "Reconnect" / "Disconnect".
    var linkGaveUp = false

    // ---- camera control -----------------------------------------------------------------------
    /// The tab on top: the card's files (the Wi-Fi flow: cameras → connect → library), the camera
    /// itself over Wi-Fi (live view + controls; needs a connection), or the camera as a USB webcam
    /// (no Wi-Fi involved, available from any screen but the connection steps).
    enum Workspace: Hashable { case files, camera, webcam }
    var workspace: Workspace = .files
    /// Leaving or re-entering playback takes a moment; the switch is locked meanwhile.
    var switchingWorkspace = false
    enum LiveView: Equatable { case off, starting, live, unavailable }
    var liveView: LiveView = .off
    /// Width / height of the live picture (portrait when the camera films vertically).
    var liveAspect: CGFloat = 16 / 9
    /// A control command in flight (the shutter key waits for the camera's answer).
    var controlBusy = false
    var controlError: String?
    let liveRenderer = LiveVideoRenderer()
    /// While connected, App Nap would coalesce the ~1 Hz keep-alive (the camera then drops playback and
    /// its AP); while downloading, idle sleep would cut the transfer.
    @ObservationIgnored var connectionActivity: NSObjectProtocol?
    /// The session is out of playback (Live): undo it (`leaveLive`) before the card can be listed or
    /// downloaded again.
    @ObservationIgnored var sessionInControl = false
    /// Bumped on every live-view start, so a timer from an earlier visit can't touch a newer one.
    @ObservationIgnored var liveStartToken = 0
    let webcam = WebcamService()
    let updater = UpdateService()
    /// Work that touches the Wi-Fi and must never overlap a new connection: the last teardown (it may
    /// still be restoring the user's network), the launch-time crash recovery, and link recovery.
    @ObservationIgnored var teardownTask: Task<Void, Never>?
    @ObservationIgnored var startupRecovery: Task<Void, Never>?
    @ObservationIgnored var recoverTask: Task<Void, Never>?

    static var thumbnailCacheDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("io.github.smithplus.osmotic/thumbs", isDirectory: true)
    }

    init() {
        configureLiveRenderer()
        // The updater quits the app to install: only ever with no camera session and no downloads.
        updater.isSafeToInstall = { [weak self] in self?.screen == .cameras && self?.transfer == nil }
        log(
            "Osmotic \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev") — log file \(logSink.url.path)"
        )
        if let demo = ProcessInfo.processInfo.environment["OSMOTIC_DEMO_MANIFEST"] {
            loadDemo(manifestPath: demo, screen: ProcessInfo.processInfo.environment["OSMOTIC_DEMO_SCREEN"])
            return
        }
        SavedCameraStore.migratePasswordsToKeychain()
        ble.startScan()
        startupRecovery = Task {
            await self.recoverInterruptedSession()
            self.updater.checkIfDue()  // after the Wi-Fi is back on the user's network
        }
    }

    /// Read once and refreshed when it changes (views read it on every render).
    var savedCameras: [SavedCamera] = SavedCameraStore.all()
    func refreshSavedCameras() { savedCameras = SavedCameraStore.all() }

    var isConnected: Bool { screen == .library }
}
