import AppKit
import Foundation
import Observation
import OsmoticCore
import SwiftUI
import UserNotifications

/// The app's single source of truth: which screen is up, the connection in progress, the camera's
/// library, and the transfer queue.
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

    // ---- connection ---------------------------------------------------------------------------
    private(set) var screen: Screen = .cameras
    private(set) var stage: Stage = .bluetooth
    private(set) var stageDetail = ""
    private(set) var datalinkProgress = 0.0
    private(set) var target: Target?
    private(set) var needsApproval = false
    var passwordPromptSSID: String?
    private(set) var connectError: String?
    private(set) var linkLost = false

    // ---- library ------------------------------------------------------------------------------
    private(set) var files: [CameraFile] = []
    private(set) var status = CameraStatus()
    private(set) var moreAvailable = false
    private(set) var loadingMore = false
    var selection: Set<String> = []
    var filter: Filter = .all
    private(set) var downloaded: Set<String> = []
    var previewFile: CameraFile?
    /// Sizes the camera's web server stated, by file id. The manifest's size is a u32 that wraps
    /// above 4 GiB, so a long 4K clip can be listed as a few hundred MB — or as nothing.
    private(set) var realSizes: [String: Int] = [:]
    @ObservationIgnored private var sizeProbed: Set<String> = []

    // ---- transfers ----------------------------------------------------------------------------
    private(set) var transfer: TransferState?
    struct TransferSummary: Equatable {
        let ok: Bool
        let text: String
    }
    private(set) var lastTransferSummary: TransferSummary?

    let ble = BluetoothService()
    let http = CameraHTTP()
    @ObservationIgnored private(set) lazy var thumbnails = ThumbnailFetcher(http: http, cacheDir: Self.thumbnailCacheDir)
    @ObservationIgnored private lazy var downloader = FileDownloader(http: http, log: { log($0) })
    @ObservationIgnored private let history = DownloadHistory()
    @ObservationIgnored private let location = LocationPermission()
    @ObservationIgnored private var flow: PairingFlow?
    @ObservationIgnored private var session: CameraSession?
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var transferTask: Task<Void, Never>?
    @ObservationIgnored private var queue: [CameraFile] = []
    @ObservationIgnored private var credentials: CheckedContinuation<(ssid: String, password: String), Error>?
    @ObservationIgnored private var armed: CheckedContinuation<Void, Error>?
    @ObservationIgnored private var isArmed = false
    @ObservationIgnored private var pendingCredentials: (ssid: String, password: String)?
    @ObservationIgnored private var previousSSID: String?
    @ObservationIgnored private var joinedCameraSSID: String?
    /// False when the camera's network was already among the Mac's saved networks before we joined.
    @ObservationIgnored private var forgetCameraNetwork = true
    /// Decoded thumbnails, bounded (~150 MB): a big card scrolled end to end must not keep them all.
    @ObservationIgnored private let thumbCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.totalCostLimit = 150 << 20
        return c
    }()

    private func cacheThumbnail(_ image: NSImage, for id: String) {
        let px = image.representations.first.map { $0.pixelsWide * $0.pixelsHigh } ?? 0
        thumbCache.setObject(image, forKey: id as NSString, cost: max(1, px * 4))
    }
    @ObservationIgnored private var connectGeneration = 0
    @ObservationIgnored private var cameraPassword: String?
    @ObservationIgnored private var recovering = false
    @ObservationIgnored private var cameraSideIP: String?
    @ObservationIgnored private var transferGeneration = 0
    private(set) var reconnecting = false
    /// Link recovery ran out of attempts: the library offers "Reconnect" / "Disconnect".
    private(set) var linkGaveUp = false

    // ---- camera control -----------------------------------------------------------------------
    /// The tab on top: the card's files (the Wi-Fi flow: cameras → connect → library), the camera
    /// itself over Wi-Fi (live view + controls; needs a connection), or the camera as a USB webcam
    /// (no Wi-Fi involved, available from any screen but the connection steps).
    enum Workspace: Hashable { case files, camera, webcam }
    private(set) var workspace: Workspace = .files
    /// Leaving or re-entering playback takes a moment; the switch is locked meanwhile.
    private(set) var switchingWorkspace = false
    enum LiveView: Equatable { case off, starting, live, unavailable }
    private(set) var liveView: LiveView = .off
    /// Width / height of the live picture (portrait when the camera films vertically).
    private(set) var liveAspect: CGFloat = 16 / 9
    /// A control command in flight (the shutter key waits for the camera's answer).
    private(set) var controlBusy = false
    private(set) var controlError: String?
    let liveRenderer = LiveVideoRenderer()
    /// While connected, App Nap would coalesce the ~1 Hz keep-alive (the camera then drops playback and
    /// its AP); while downloading, idle sleep would cut the transfer.
    @ObservationIgnored private var connectionActivity: NSObjectProtocol?
    /// The session is out of playback (Live): undo it (`leaveLive`) before the card can be listed or
    /// downloaded again.
    @ObservationIgnored private var sessionInControl = false
    /// Bumped on every live-view start, so a timer from an earlier visit can't touch a newer one.
    @ObservationIgnored private var liveStartToken = 0
    let webcam = WebcamService()
    let updater = UpdateService()
    /// Work that touches the Wi-Fi and must never overlap a new connection: the last teardown (it may
    /// still be restoring the user's network), the launch-time crash recovery, and link recovery.
    @ObservationIgnored private var teardownTask: Task<Void, Never>?
    @ObservationIgnored private var startupRecovery: Task<Void, Never>?
    @ObservationIgnored private var recoverTask: Task<Void, Never>?

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

    /// UI demo without hardware: a captured manifest on screen, or the connection stepper mid-way.
    /// `OSMOTIC_DEMO_MANIFEST=<file.bin> [OSMOTIC_DEMO_SCREEN=connecting|cameras|camera|webcam] [OSMOTIC_DEMO_THUMBS=<dir>]`.
    private func loadDemo(manifestPath: String, screen demoScreen: String?) {
        log("demo: \(manifestPath)")
        let bytes = (try? Data(contentsOf: URL(fileURLWithPath: manifestPath))).map { [UInt8]($0) } ?? []
        target = Target(id: UUID(), name: "OsmoPocket3-D1E9", model: CameraModel.resolve(modelId: 0x20, name: nil), modelId: 0x20)
        files = ManifestDecoder.inferMissingExtensions(ManifestDecoder.decodeBlob(bytes)).sorted {
            $0.timestamp != $1.timestamp ? $0.timestamp > $1.timestamp : $0.seq > $1.seq
        }
        var st = CameraStatus()
        st.batteryPercent = 76
        st.sdTotalMb = 121_785
        st.sdFreeMb = 68_131
        status = st
        moreAvailable = false
        refreshDownloaded()
        if let dir = ProcessInfo.processInfo.environment["OSMOTIC_DEMO_THUMBS"],
            let names = try? FileManager.default.contentsOfDirectory(atPath: dir).filter({ $0.hasSuffix(".jpg") }).sorted(),
            !names.isEmpty
        {
            for (i, f) in files.enumerated() {
                if let img = NSImage(contentsOfFile: dir + "/" + names[i % names.count]) { cacheThumbnail(img, for: f.id) }
            }
        }
        switch demoScreen {
        case "connecting":
            screen = .connecting
            stage = .pairing
            needsApproval = true
            stageDetail = String(localized: "Approve the connection on the camera’s screen")
        case "webcam":
            screen = .cameras
            workspace = .webcam
        case "camera":
            screen = .library
            workspace = .camera
            liveView = .live
            var st = status
            st.captureMode = .video
            st.recording = true
            st.recordingSeconds = 754
            status = st
        case "cameras":
            screen = .cameras
            ble.injectDemo(
                DiscoveredCamera(
                    id: UUID(), name: "OsmoPocket3-D1E9", rssi: -41, modelId: 0x20,
                    model: CameraModel.resolve(modelId: 0x20, name: nil), brand: .dji, lastSeen: Date()))
            // Demo data only: never the user's own saved cameras in a screenshot.
            savedCameras = [
                SavedCamera(
                    id: UUID(), bleName: "OsmoAction5Pro-4C2A", modelId: 0x15, modelName: "Osmo Action 5 Pro",
                    lastConnected: Date().addingTimeInterval(-86_400 * 3))
            ]
        default:
            screen = .library
            if let first = files.first { downloaded.insert(first.id) }
            if files.count > 3 { selection = [files[1].id, files[2].id] }
            if let clip = files.first(where: \.isVideo) {
                var t = TransferState(total: 4, bytesTotal: 2_070_000_000)
                t.done = 1
                t.current = clip
                currentTransferId = clip.id
                queuedIds = [clip.id]
                t.currentSize = clip.sizeBytes
                t.currentBytes = clip.sizeBytes / 3
                t.bytesDone = 600_000_000
                t.speed = 32_400_000
                transfer = t
            }
        }
    }

    /// Read once and refreshed when it changes (views read it on every render).
    private(set) var savedCameras: [SavedCamera] = SavedCameraStore.all()
    func refreshSavedCameras() { savedCameras = SavedCameraStore.all() }

    var isConnected: Bool { screen == .library }

    // =========================================================================================
    // MARK: Connect
    // =========================================================================================

    func connect(_ camera: DiscoveredCamera) {
        start(Target(id: camera.id, name: camera.name, model: camera.model, modelId: camera.modelId))
    }

    func connect(saved: SavedCamera) {
        let model = CameraModel.resolve(modelId: saved.modelId, name: saved.bleName)
        start(Target(id: saved.id, name: saved.bleName, model: model, modelId: saved.modelId))
    }

    private func start(_ t: Target) {
        guard screen != .connecting || connectError != nil else { return }
        target = t
        connectError = nil
        needsApproval = false
        passwordPromptSSID = nil
        linkLost = false
        linkGaveUp = false
        wifiRestoreFailed = false
        lastTransferSummary = nil
        recoverTask?.cancel()
        stage = .bluetooth
        stageDetail = String(localized: "Looking for \(t.name)…")
        datalinkProgress = 0
        screen = .connecting
        ble.stopScan()
        LocalNetworkPermission.prime()
        log("=== connect \(t.name) [\(t.model.name)] port=\(t.model.datalinkPort) poke=\(t.model.tcpPoke) ===")
        connectGeneration += 1
        let gen = connectGeneration
        let previous = connectTask
        let pendingWifiWork = [teardownTask, startupRecovery, recoverTask]
        connectTask = Task { [weak self] in
            // A cancelled attempt cleans up after itself; never overlap it with the next one, nor with
            // a Wi-Fi restore still in flight.
            await previous?.value
            for work in pendingWifiWork { await work?.value }
            guard let self, self.connectGeneration == gen else { return }
            await self.runConnect(t, generation: gen)
        }
    }

    func cancelConnect() {
        log("connect: cancelled by user")
        connectGeneration += 1
        connectTask?.cancel()
        // Stop a datalink handshake now rather than after its ~14 s of retries (close is idempotent).
        if let s = session { Task { await s.close() } }
        failPending(CancellationError())
        passwordPromptSSID = nil
        needsApproval = false
        screen = .cameras
        ble.startScan()
    }

    private func runConnect(_ t: Target, generation gen: Int) async {
        /// Still the attempt the user is waiting for? Checked after every suspension.
        func live() throws {
            if Task.isCancelled || gen != connectGeneration { throw CancellationError() }
        }
        // Begun here, after any earlier teardown finished (its end would otherwise end ours). App Nap
        // would coalesce the keep-alive; idle sleep is held off only while downloading (`enqueue`).
        if connectionActivity == nil {
            connectionActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep], reason: "Connected to a camera")
        }
        do {
            // Remember where the Mac's Wi-Fi was, to return there afterwards.
            if location.isUndetermined { await location.request() }
            try live()
            previousSSID = WiFiService.currentSSID()
            if let stale = Preferences.pendingCameraSSID, previousSSID == stale { previousSSID = Preferences.pendingRestoreSSID }
            log("wifi: current network \(previousSSID.map(redactedSSID) ?? "unknown (no Location permission or not on Wi-Fi)")")

            // 1. Bluetooth + pairing → the camera's own Wi-Fi credentials.
            let (ssid, password) = try await pairAndGetCredentials(t)
            try live()
            cameraPassword = password
            // Already sitting on the camera's AP (a previous run)? Then that is not "home".
            if previousSSID == ssid { previousSSID = nil }

            // 2. Join the camera's access point.
            stage = .wifi
            stageDetail = String(localized: "Waiting for the camera to turn on its Wi-Fi…")
            // A network the Mac already knew stays known afterwards (a leftover from our own crashed
            // run doesn't count).
            let alreadySaved = await WiFiService.isSavedNetwork(ssid) && Preferences.pendingCameraSSID != ssid
            try live()
            forgetCameraNetwork = !alreadySaved
            Preferences.pendingRestoreSSID = previousSSID
            Preferences.pendingCameraSSID = ssid
            Preferences.pendingForgetCamera = !alreadySaved
            joinedCameraSSID = ssid
            try await Task.sleep(for: .seconds(3))
            let joined = try await WiFiService.join(ssid: ssid, password: password, timeout: 75) { text in
                Task { @MainActor [weak self] in self?.stageDetail = text }
            }
            cameraSideIP = joined.ip
            Preferences.pendingCameraSideIP = joined.ip
            try live()

            // 3. Datalink: register, playback, newest page.
            stage = .datalink
            stageDetail = String(localized: "Reading the camera’s card…")
            let s = makeSession(model: t.model, interface: joined.interface)
            s.onProgress = { p in Task { @MainActor [weak self] in self?.datalinkProgress = p } }
            session = s  // owned from here on: teardown closes it on any exit
            let result = await s.connect()
            try live()
            guard result.handshakeOk else {
                throw ConnectError.message(
                    String(
                        localized:
                            "The camera didn’t answer on the data link. If macOS asked about local network access, allow it and try again."
                    ))
            }

            // 4. Library.
            stage = .library
            stageDetail =
                result.files.isEmpty ? String(localized: "The card is empty") : String(localized: "\(result.files.count) files")
            let resolved = await http.resolveStorage(result.files, singleSdStorage: result.model.singleSdStorage)
            try live()
            files = resolved
            moreAvailable = result.moreAvailable
            refreshDownloaded()
            SavedCameraStore.save(
                SavedCamera(
                    id: t.id, bleName: t.name, modelId: t.modelId,
                    modelName: result.model.name, lastConnected: Date()))
            refreshSavedCameras()
            screen = .library
            log("library: \(files.count) files on screen, more=\(moreAvailable)")
            Task { await loadOlderWhileNew() }
        } catch {
            let superseded = error is CancellationError || gen != connectGeneration
            if superseded {
                log("connect: attempt ended (cancelled) — cleaning up")
            } else {
                log("connect: FAILED — \(error.localizedDescription)")
                connectError = error.localizedDescription
            }
            await cleanup(restoreWifi: true)
        }
    }

    private func makeSession(model: CameraModel, interface: String) -> CameraSession {
        let s = CameraSession(model: model, interfaceName: interface, log: { log($0) })
        s.onStatus = { st in Task { @MainActor [weak self] in self?.status = st } }
        // Weak: the session keeps these closures, and they must not keep the session (one leak per connect).
        s.onLinkLost = { [weak s] in
            Task { @MainActor [weak self] in if let s { self?.handleLinkLost(from: s) } }
        }
        s.onLinkRestored = { [weak s] in
            Task { @MainActor [weak self] in if let s { self?.handleLinkRestored(from: s) } }
        }
        return s
    }

    enum ConnectError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let m) = self { m } else { nil } }
    }

    private func pairAndGetCredentials(_ t: Target) async throws -> (String, String) {
        guard ble.power == .poweredOn else {
            throw ConnectError.message(
                ble.power == .unauthorized
                    ? String(
                        localized:
                            "Osmotic doesn’t have Bluetooth permission. Turn it on in System Settings › Privacy & Security › Bluetooth."
                    )
                    : String(localized: "The Mac’s Bluetooth is off."))
        }
        let flow = PairingFlow(bleName: t.name, savedPassword: SavedCameraStore.password(for: t.id))
        self.flow = flow
        flow.log = { log($0) }
        flow.write = { [weak self] in self?.ble.write($0) }
        flow.schedule = { delay, body in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                body()
            }
        }
        flow.emit = { [weak self] in self?.handlePairing($0) }
        ble.onMessage = { [weak self] in self?.flow?.onMessage($0) }
        ble.onReady = { [weak self] in
            guard let self else { return }
            self.stage = .pairing
            self.stageDetail = String(localized: "Pairing with the camera…")
            self.isArmed = true
            self.armed?.resume()
            self.armed = nil
            self.flow?.onReady()
        }
        ble.onDisconnect = { [weak self] error in
            guard let self, self.stage <= .pairing, self.screen == .connecting else { return }
            if self.ble.power != .poweredOn {
                self.failPending(ConnectError.message(String(localized: "The Mac’s Bluetooth is off.")))
                return
            }
            self.failPending(
                ConnectError.message(
                    String(localized: "The camera closed the Bluetooth connection.")
                        + (error.map { " (\($0.localizedDescription))" } ?? "")))
        }

        isArmed = false
        pendingCredentials = nil
        guard ble.connect(t.id) else {
            throw ConnectError.message(String(localized: "Can’t find the camera. Turn it on and bring it close to the Mac."))
        }
        // Bluetooth link + GATT armed.
        try await withTimeout(25, message: String(localized: "Couldn’t connect over Bluetooth. Is the camera on and nearby?")) {
            [self] in
            if isArmed { return }
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in armed = c }
        }
        // Pairing → credentials. Approval on the camera screen can take a while.
        return try await withTimeout(
            120, message: String(localized: "The camera didn’t hand over its Wi-Fi. Try turning it off and on again.")
        ) { [self] in
            if let p = pendingCredentials { return (p.ssid, p.password) }
            let c = try await withCheckedThrowingContinuation {
                (c: CheckedContinuation<(ssid: String, password: String), Error>) in
                credentials = c
            }
            return (c.ssid, c.password)
        }
    }

    private func handlePairing(_ event: PairingFlow.Event) {
        switch event {
        case .approvalRequired:
            needsApproval = true
            stageDetail = String(localized: "Approve the connection on the camera’s screen")
        case .paired:
            needsApproval = false
            stageDetail = String(localized: "Asking the camera for its Wi-Fi network…")
        case .credentials(let ssid, let password):
            passwordPromptSSID = nil
            if let c = credentials {
                c.resume(returning: (ssid, password))
                credentials = nil
            } else {
                pendingCredentials = (ssid, password)
            }
        case .needsPassword(let ssid):
            stageDetail = String(localized: "Enter the camera’s Wi-Fi password")
            passwordPromptSSID = ssid
        case .notActivated:
            failPending(
                ConnectError.message(
                    String(
                        localized:
                            "This camera was never activated, so it won’t turn on its Wi-Fi. Activate it once with DJI Mimo.")))
        }
    }

    func providePassword(_ password: String) {
        passwordPromptSSID = nil
        // This camera doesn't send its passphrase over BLE, so keep the one the user typed for next time.
        if let t = target { SavedCameraStore.setPassword(password, for: t.id) }
        flow?.providePassword(password)
    }

    private func failPending(_ error: Error) {
        armed?.resume(throwing: error)
        armed = nil
        credentials?.resume(throwing: error)
        credentials = nil
    }

    /// Run `body`, failing with `message` if it takes longer than `seconds`.
    private func withTimeout<T: Sendable>(
        _ seconds: Double, message: String,
        _ body: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        let timer = Task { @MainActor [weak self] in
            try await Task.sleep(for: .seconds(seconds))
            // The stage may have finished while this was waking up: never fail the next one.
            guard !Task.isCancelled else { return }
            self?.failPending(ConnectError.message(message))
        }
        defer { timer.cancel() }
        return try await body()
    }

    // =========================================================================================
    // MARK: Disconnect
    // =========================================================================================

    /// Returning the Wi-Fi is in progress (shown on the cameras screen).
    private(set) var restoringWifi = false
    /// The automatic return to the user's network failed; they have to pick one in the menu bar.
    private(set) var wifiRestoreFailed = false

    /// `keepSummary`: leave the "Done: …" line up (the automatic disconnect after downloads shows it
    /// on the cameras screen).
    func disconnect(keepSummary: Bool = false) async {
        log("=== disconnect ===")
        transferGeneration += 1
        transferTask?.cancel()
        transferTask = nil
        // Stop link recovery and wait for it: a join still in flight could put the Mac back on the
        // camera's network while the teardown restores the user's.
        let recovery = recoverTask
        recoverTask = nil
        recovery?.cancel()
        queue.removeAll()
        queuedIds = []
        currentTransferId = nil
        transfer = nil
        connectGeneration += 1
        files = []
        selection = []
        cursor = nil
        workspace = .files
        sessionInControl = false
        liveView = .off
        liveRenderer.reset()
        controlError = nil
        previewFile = nil
        if !keepSummary { lastTransferSummary = nil }
        retryCounts = [:]
        realSizes = [:]
        sizeProbed = []
        thumbCache.removeAllObjects()
        moreAvailable = false
        status = CameraStatus()
        linkLost = false
        linkGaveUp = false
        screen = .cameras
        await recovery?.value
        await cleanup(restoreWifi: Preferences.restoreWifi)
        ble.startScan()
        updater.checkIfDue()  // back on the user's network: a good moment
    }

    /// Teardown in a task of its own, so a cancelled caller (a cancelled connect, the transfer queue
    /// that asked for "disconnect when done") can't cut the Wi-Fi restore short.
    private func cleanup(restoreWifi: Bool) async {
        let task = Task { @MainActor in await self.teardown(restoreWifi: restoreWifi) }
        teardownTask = task
        await task.value
    }

    private func teardown(restoreWifi: Bool) async {
        defer {
            if let a = connectionActivity { ProcessInfo.processInfo.endActivity(a); connectionActivity = nil }
        }
        flow?.cancel()
        flow = nil
        ble.onDisconnect = nil
        ble.onReady = nil
        ble.onMessage = nil
        ble.disconnect()
        if let s = session {
            session = nil
            await s.close()
        }
        if let cam = joinedCameraSSID {
            joinedCameraSSID = nil
            if restoreWifi {
                restoringWifi = true
                stageDetail = String(localized: "Going back to your Wi-Fi…")
                let back = await WiFiService.restore(
                    previous: previousSSID, cameraSSID: cam, cameraSideIP: cameraSideIP,
                    forgetCamera: forgetCameraNetwork)
                wifiRestoreFailed = !back
                restoringWifi = false
            }
        }
        cameraPassword = nil
        cameraSideIP = nil
        Preferences.pendingRestoreSSID = nil
        Preferences.pendingCameraSSID = nil
        Preferences.pendingCameraSideIP = nil
    }

    /// Wait for any Wi-Fi restore still running (quitting), including the cleanup of a connect
    /// attempt that was just cancelled — it runs in that attempt's task.
    func finishWifiWork() async {
        for work in [connectTask, recoverTask, teardownTask, startupRecovery] { await work?.value }
        await teardownTask?.value  // the cancelled attempt's cleanup may have replaced it meanwhile
    }

    func backToCameras() {
        connectError = nil
        screen = .cameras
        ble.startScan()
    }

    func retry() {
        guard let t = target else { return }
        start(t)  // clears the error itself; `start` only runs while one is showing
    }

    private func handleLinkLost(from s: CameraSession) {
        guard screen == .library, session === s else { return }  // ignore a replaced session's last words
        linkLost = true
        if workspace == .camera {
            // Nothing on Live works without the link; show the card (and the recovery banner) instead.
            workspace = .files
            liveView = .off
            liveRenderer.reset()
        }
        log("library: camera link lost — trying to recover")
        if !recovering { recoverTask = Task { await recoverLink() } }
    }

    /// "Reconnect" after link recovery gave up.
    func reconnectLink() {
        guard screen == .library, linkLost, !recovering else { return }
        linkGaveUp = false
        recoverTask = Task { await recoverLink() }
    }

    private func handleLinkRestored(from s: CameraSession) {
        guard linkLost, session === s else { return }
        linkLost = false
        log("library: camera link restored")
        // The same session came back while out of playback: put it back into playback for the card.
        if sessionInControl { Task { await leaveLive() } }
    }

    /// The camera went quiet: rejoin its AP if the Mac left it, and re-register a fresh session if
    /// the old one doesn't come back by itself. The file list stays as it is.
    private func recoverLink() async {
        guard !recovering, let t = target, let ssid = joinedCameraSSID, let pass = cameraPassword else { return }
        recovering = true
        reconnecting = true
        defer { recovering = false; reconnecting = false }
        let gen = connectGeneration
        func stillWanted() -> Bool { !Task.isCancelled && screen == .library && gen == connectGeneration && linkLost }
        for attempt in 1...3 {
            try? await Task.sleep(for: .seconds(4))
            guard stillWanted() else { return }
            log("recover: attempt \(attempt)")
            var iface = WiFiService.interfaceName ?? "en0"
            if !(await WiFiService.isCameraReachable()) {
                do {
                    let joined = try await WiFiService.join(ssid: ssid, password: pass, timeout: 40) { _ in }
                    iface = joined.interface
                    cameraSideIP = joined.ip ?? cameraSideIP
                } catch {
                    log("recover: Wi-Fi rejoin failed (\(error.localizedDescription))")
                    continue
                }
            }
            guard stillWanted() else { return }
            // Give the old session a moment to hear the camera again before replacing it.
            try? await Task.sleep(for: .seconds(3))
            guard stillWanted() else { return }
            if let old = session { session = nil; await old.close() }
            guard stillWanted() else { return }
            let s = makeSession(model: t.model, interface: iface)
            session = s
            sessionInControl = false  // a fresh session starts in playback
            let result = await s.connect()
            guard screen == .library, gen == connectGeneration, session === s else {
                if session === s { session = nil }
                await s.close()
                return
            }
            if result.handshakeOk {
                linkLost = false
                let known = Set(files.map(\.id))
                let fresh = await http.resolveStorage(result.files, singleSdStorage: result.model.singleSdStorage)
                    .filter { !known.contains($0.id) }
                guard gen == connectGeneration, session === s else { return }
                if !fresh.isEmpty {
                    files = (fresh + files).sorted {
                        $0.timestamp != $1.timestamp ? $0.timestamp > $1.timestamp : $0.seq > $1.seq
                    }
                    refreshDownloaded()
                }
                moreAvailable = moreAvailable || result.moreAvailable
                log("recover: session re-established (\(fresh.count) new file(s))")
                return
            }
            session = nil
            await s.close()
        }
        log("recover: gave up after 3 attempts")
        if stillWanted() { linkGaveUp = true }
    }

    /// Wait (bounded) for the link to come back — used by the transfer loop before retrying a file.
    private func waitForLink(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !linkLost && !reconnecting { return true }
            if Task.isCancelled || screen != .library || linkGaveUp { return false }
            try? await Task.sleep(for: .seconds(1))
        }
        return !linkLost
    }

    /// A previous run that died while on the camera's AP left a marker; put the Wi-Fi back.
    private func recoverInterruptedSession() async {
        guard let cam = Preferences.pendingCameraSSID else { return }
        let current = WiFiService.currentSSID()
        let onCamera: Bool
        if let current {
            onCamera = current == cam
        } else {
            // No SSID without Location permission: the camera answering at 192.168.2.1 isn't enough (a
            // home router can live there too) — the Mac must also still hold the address it had.
            let reachable = await WiFiService.isCameraReachable()
            let sameAddress =
                Preferences.pendingCameraSideIP.map { ip in
                    WiFiService.interfaceName.flatMap(WiFiService.ipv4Address) == ip
                } ?? true
            onCamera = reachable && sameAddress
        }
        if onCamera {
            log("wifi: recovering from an interrupted session on \(cam)")
            restoringWifi = true
            let back = await WiFiService.restore(
                previous: Preferences.pendingRestoreSSID, cameraSSID: cam, cameraSideIP: nil,
                forgetCamera: Preferences.pendingForgetCamera)
            wifiRestoreFailed = !back
            restoringWifi = false
        }
        Preferences.pendingRestoreSSID = nil
        Preferences.pendingCameraSSID = nil
        Preferences.pendingCameraSideIP = nil
    }

    // =========================================================================================
    // MARK: Library
    // =========================================================================================

    var visibleFiles: [CameraFile] {
        switch filter {
        case .all: files
        case .videos: files.filter(\.isVideo)
        case .photos: files.filter(\.isImage)
        case .favorites: files.filter(\.starred)
        case .new: files.filter { !downloaded.contains($0.id) }
        }
    }

    var newFiles: [CameraFile] { files.filter { !downloaded.contains($0.id) } }

    /// Files waiting in the transfer queue or downloading now. Stored (not derived from `transfer`) so
    /// the grid's cells don't re-render on every progress tick.
    private(set) var queuedIds: Set<String> = []
    /// The file downloading right now (only its cell follows the progress).
    private(set) var currentTransferId: String?

    /// New files not already on their way.
    var newNotQueued: [CameraFile] {
        let q = queuedIds
        return newFiles.filter { !q.contains($0.id) }
    }

    func isDownloaded(_ f: CameraFile) -> Bool { downloaded.contains(f.id) }

    func isOnDisk(_ f: CameraFile) -> Bool { FileManager.default.fileExists(atPath: DownloadPaths.destination(for: f).path) }

    private func refreshDownloaded() {
        let fm = FileManager.default
        downloaded = Set(
            files.filter { f in
                history.contains(f) || fm.fileExists(atPath: DownloadPaths.destination(for: f).path)
            }.map(\.id))
        probeRealSizes()
    }

    /// The size to show and to count on: the server's when known, else the manifest's.
    func size(of f: CameraFile) -> Int { realSizes[f.id] ?? f.sizeBytes }

    /// One HEAD per clip whose listed size can't be trusted: videos over two minutes (4 GiB is about
    /// four minutes of 4K at the Pocket 3's top bitrate) and files listed without a size.
    private func probeRealSizes() {
        let candidates = files.filter { f in
            !sizeProbed.contains(f.id) && f.isVideo && (f.durationSec >= 120 || f.sizeBytes <= 0)
        }
        guard !candidates.isEmpty, let s = session else { return }
        sizeProbed.formUnion(candidates.map(\.id))
        Task { [weak self] in
            for f in candidates {
                guard let self, self.session === s, !self.sessionInControl else { return }
                guard let head = await self.http.headStatus(f.originalURLPath), head.status == 200, head.length > 0
                else { self.sizeProbed.remove(f.id); continue }
                guard self.session === s, head.length != self.size(of: f) else { continue }
                let before = self.size(of: f)
                self.realSizes[f.id] = head.length
                // Queued but not started: fix the total now. The file downloading now is fixed by the
                // downloader's own report of the size (`transferRealSize`).
                if self.queue.contains(where: { $0.id == f.id }), var t = self.transfer {
                    t.bytesTotal += head.length - max(0, before)
                    self.transfer = t
                }
                log("library: \(f.name) is \(head.length / 1_000_000) MB (listed as \(f.sizeBytes / 1_000_000) MB)")
            }
        }
    }

    func loadMoreIfNeeded() {
        guard moreAvailable, !loadingMore, session != nil else { return }
        Task { await loadOlderPage() }
    }

    /// Fetch one older page; returns how many of its files are not yet downloaded.
    @discardableResult
    private func loadOlderPage() async -> Int {
        guard moreAvailable, !loadingMore, let s = session else { return 0 }
        loadingMore = true
        defer { loadingMore = false }
        let page = await s.nextPage()
        guard session === s else { return 0 }
        let resolved = await http.resolveStorage(page.files, singleSdStorage: s.model.singleSdStorage)
        guard session === s else { return 0 }  // disconnected (or replaced) while resolving
        let known = Set(files.map(\.id))
        let added = resolved.filter { !known.contains($0.id) }
        files += added
        files.sort { $0.timestamp != $1.timestamp ? $0.timestamp > $1.timestamp : $0.seq > $1.seq }
        moreAvailable = page.moreAvailable
        refreshDownloaded()
        let fresh = added.filter { !downloaded.contains($0.id) }.count
        log("library: +\(added.count) older files (\(fresh) not downloaded), more=\(moreAvailable)")
        return fresh
    }

    /// New footage sits at the top of the card, so keep paging back while pages still bring files that
    /// aren't on the Mac — "Download New" then covers a whole trip, not just the newest 45.
    private func loadOlderWhileNew() async {
        var pages = 0
        while screen == .library, workspace != .camera, moreAvailable, pages < 40 {
            let newOnTop = files.isEmpty || !newFiles.isEmpty
            guard newOnTop else { break }
            if await loadOlderPage() == 0 { break }
            pages += 1
        }
    }

    func thumbnail(for f: CameraFile) async -> NSImage? {
        if let img = thumbCache.object(forKey: f.id as NSString) { return img }
        guard let data = await thumbnails.thumbnail(for: f), let img = NSImage(data: data) else { return nil }
        cacheThumbnail(img, for: f.id)
        return img
    }

    func cachedThumbnail(for f: CameraFile) -> NSImage? { thumbCache.object(forKey: f.id as NSString) }

    @ObservationIgnored private var selectionAnchor: String?
    /// The keyboard's place in the grid (arrow keys move it; it gets a focus outline).
    private(set) var cursor: String?

    /// A click on a cell, Finder-style: plain selects just this one (again to clear), ⌘ adds or
    /// removes it, ⇧ selects the range from the last clicked file.
    func click(_ f: CameraFile, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.shift), let anchor = selectionAnchor,
            let a = visibleFiles.firstIndex(where: { $0.id == anchor }),
            let b = visibleFiles.firstIndex(where: { $0.id == f.id })
        {
            selection.formUnion(visibleFiles[min(a, b)...max(a, b)].map(\.id))
            return
        }
        if modifiers.contains(.command) {
            toggleInSelection(f)
            return
        }
        selection = selection == [f.id] ? [] : [f.id]
        selectionAnchor = f.id
        cursor = f.id
    }

    /// Arrow keys: move the cursor to `id` and select it; with ⇧, extend from the anchor instead.
    func moveCursor(to id: String, extend: Bool) {
        cursor = id
        if extend, let anchor = selectionAnchor,
            let a = visibleFiles.firstIndex(where: { $0.id == anchor }),
            let b = visibleFiles.firstIndex(where: { $0.id == id })
        {
            selection = Set(visibleFiles[min(a, b)...max(a, b)].map(\.id))
        } else {
            selection = [id]
            selectionAnchor = id
        }
    }

    /// The checkbox on a thumbnail: add or remove this file, keeping the rest.
    func toggleInSelection(_ f: CameraFile) {
        if selection.contains(f.id) { selection.remove(f.id) } else { selection.insert(f.id) }
        selectionAnchor = f.id
    }

    func selectAllVisible() { selection = Set(visibleFiles.map(\.id)) }

    /// Space bar: preview the selected file (the first, if several).
    func previewSelection() {
        previewFile = visibleFiles.first { selection.contains($0.id) }
    }

    /// ← / → inside the preview.
    func stepPreview(by delta: Int) {
        guard let current = previewFile, let i = visibleFiles.firstIndex(where: { $0.id == current.id }) else { return }
        let j = i + delta
        guard visibleFiles.indices.contains(j) else { return }
        previewFile = visibleFiles[j]
        selection = [visibleFiles[j].id]
        selectionAnchor = visibleFiles[j].id
    }

    func selectNew() { selection = Set(newFiles.map(\.id)) }

    var selectedFiles: [CameraFile] { files.filter { selection.contains($0.id) } }

    func revealInFinder(_ f: CameraFile) {
        let url = DownloadPaths.destination(for: f)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            openDownloadFolder()
        }
    }

    func openDownloadFolder() {
        let dir = Preferences.downloadFolder
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    // =========================================================================================
    // MARK: Transfers
    // =========================================================================================

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

    func downloadNew() { enqueue(newNotQueued) }

    /// Shows the "cancel the download?" confirmation first when files are still coming in.
    var confirmingDisconnect = false

    func requestDisconnect() {
        if transfer != nil && screen == .library { confirmingDisconnect = true } else { Task { await disconnect() } }
    }

    func downloadSelected() { enqueue(selectedFiles) }

    func enqueue(_ list: [CameraFile]) {
        let fresh = list.filter { !queuedIds.contains($0.id) }
        guard !fresh.isEmpty else { return }
        // Oldest first, so an interrupted run leaves a contiguous, dated set on disk.
        queue += fresh.sorted { $0.timestamp != $1.timestamp ? $0.timestamp < $1.timestamp : $0.seq < $1.seq }
        queuedIds.formUnion(fresh.map(\.id))
        let bytes = fresh.reduce(0) { $0 + max(0, size(of: $1)) }
        if var t = transfer {
            t.total += fresh.count
            t.bytesTotal += bytes
            transfer = t
        } else {
            transfer = TransferState(total: fresh.count, bytesTotal: bytes)
        }
        lastTransferSummary = nil
        log("transfer: queued \(fresh.count) file(s), \(bytes / 1_000_000) MB")
        TransferNotifier.prepare()
        if transferTask == nil {
            let gen = transferGeneration
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled], reason: "Downloading from the camera")
            transferTask = Task { [weak self] in
                await self?.runQueue(generation: gen)
                ProcessInfo.processInfo.endActivity(activity)
                if self?.transferGeneration == gen { self?.transferTask = nil }
            }
        }
    }

    func cancelTransfers() {
        log("transfer: cancelled by user")
        transferGeneration += 1
        queue.removeAll()
        queuedIds = []
        currentTransferId = nil
        transferTask?.cancel()
        transferTask = nil
        transfer = nil
        lastTransferSummary = TransferSummary(
            ok: false, text: String(localized: "Download cancelled. What already arrived is saved."))
    }

    private func runQueue(generation gen: Int) async {
        var saved = 0
        func current() -> Bool { gen == transferGeneration && !Task.isCancelled }
        while current(), !queue.isEmpty {
            let f = queue.removeFirst()
            transfer?.current = f
            currentTransferId = f.id
            transfer?.currentBytes = 0
            transfer?.currentSize = max(0, size(of: f))
            let dest = DownloadPaths.destination(for: f)
            log("transfer: \(f.name) → \(dest.path)")
            speedSample = (Date(), -1)  // seeded by the first report, which includes any resumed bytes
            let result = await downloader.download(
                urlPath: f.originalURLPath, to: dest, expectedSize: size(of: f),
                onTotal: { total in Task { @MainActor [weak self] in self?.transferRealSize(fileId: f.id, total: total) } },
                progress: { bytes in Task { @MainActor [weak self] in self?.transferProgress(fileId: f.id, bytes: bytes) } }
            )
            switch result {
            case .saved(let url), .skipped(let url):
                if case .saved = result { saved += 1; stampDates(url, f) }
                history.insert(f)
                downloaded.insert(f.id)
                log("transfer: \(f.name) \(result == .skipped(url) ? "already on disk" : "saved")")
                if Preferences.includeSidecars && current() { await fetchSidecar(of: f, next: dest) }
            case .paused(let bytes):
                // The camera or its AP dropped out mid-file: once the link is back, resume this file.
                let retries = retryCounts[f.id, default: 0]
                let unreachable = linkLost ? true : !(await WiFiService.isCameraReachable())
                if retries < 2, current(), unreachable {
                    log("transfer: \(f.name) paused at \(bytes / 1_000_000) MB — waiting for the camera to come back")
                    if await waitForLink(timeout: 120), current() {
                        retryCounts[f.id] = retries + 1
                        queue.insert(f, at: 0)
                        transfer?.current = nil
                        continue
                    }
                }
                guard current() else { break }
                transfer?.failed.append(f.name)
                log("transfer: \(f.name) paused at \(bytes / 1_000_000) MB")
                if linkGaveUp {
                    // The camera is gone: don't walk the rest of the queue through timeouts one by one.
                    transfer?.failed += queue.map(\.name)
                    log("transfer: camera unreachable — stopping the queue (\(queue.count) left for next time)")
                    queue.removeAll()
                }
            case .failed(let why):
                transfer?.failed.append(f.name)
                log("transfer: \(f.name) FAILED — \(why)")
            case .cancelled:
                log("transfer: \(f.name) cancelled (partial kept for resume)")
            }
            guard gen == transferGeneration else { return }
            queuedIds.remove(f.id)
            currentTransferId = nil
            if var t = transfer {
                t.done += 1
                t.bytesDone += max(0, t.currentSize)  // the real size when the server stated it
                t.currentBytes = 0
                t.current = nil
                transfer = t
            }
        }
        // A newer run (or a cancel) owns the transfer state now.
        guard gen == transferGeneration else { return }
        let failed = transfer?.failed ?? []
        let cancelled = Task.isCancelled
        transfer = nil
        queuedIds = []
        currentTransferId = nil
        let folderName = Preferences.downloadFolder.lastPathComponent
        lastTransferSummary =
            cancelled
            ? TransferSummary(ok: false, text: String(localized: "Download cancelled"))
            : failed.isEmpty
                ? TransferSummary(
                    ok: true, text: String(localized: "Done: \(String(localized: "\(saved) files")) in \(folderName)"))
                : TransferSummary(
                    ok: false, text: String(localized: "\(failed.count) files couldn’t be downloaded. Try again to resume."))
        log("transfer: finished — \(lastTransferSummary?.text ?? "")")
        if !cancelled { TransferNotifier.finished(saved: saved, failed: failed.count, folder: Preferences.downloadFolder) }
        if !cancelled && failed.isEmpty && Preferences.disconnectWhenDone && screen == .library {
            // Not awaited: disconnect() cancels this very task.
            Task { @MainActor in await self.disconnect(keepSummary: true) }
        }
    }

    @ObservationIgnored private var speedSample = (time: Date(), bytes: 0)
    @ObservationIgnored private var retryCounts: [String: Int] = [:]

    /// The server's size for the file downloading now. The manifest's is a u32 that wraps above 4 GiB
    /// (a long 4K clip can be listed as 0 MB), which pinned the bar at 100% with the time left at 0.
    private func transferRealSize(fileId: String, total: Int) {
        guard var t = transfer, t.current?.id == fileId, total > 0, total != t.currentSize else { return }
        t.bytesTotal += total - t.currentSize
        t.currentSize = total
        transfer = t
        realSizes[fileId] = total
        log(
            "transfer: \(t.current?.name ?? fileId) is \(total / 1_000_000) MB (listed as \((t.current?.sizeBytes ?? 0) / 1_000_000) MB)"
        )
    }

    private func transferProgress(fileId: String, bytes: Int) {
        guard var t = transfer, t.current?.id == fileId else { return }
        let now = Date()
        if speedSample.bytes < 0 { speedSample = (now, bytes) }
        let dt = now.timeIntervalSince(speedSample.time)
        if dt > 0.4 {
            let inst = Double(max(0, bytes - speedSample.bytes)) / dt
            t.speed = t.speed == 0 ? inst : t.speed * 0.7 + inst * 0.3
            speedSample = (now, bytes)
        }
        t.currentBytes = bytes
        transfer = t
    }

    /// A RAW `.DNG` beside a JPEG, or an audio-backup `.WAV` beside a clip, is never listed; one HEAD
    /// tells whether it exists.
    private func fetchSidecar(of f: CameraFile, next dest: URL) async {
        guard let side = f.sidecarCandidate() else { return }
        guard let head = await http.headStatus(side.originalURLPath), head.status == 200 else { return }
        let sideDest = dest.deletingLastPathComponent().appendingPathComponent(side.localName)
        log("transfer: sidecar \(side.name) exists (\(head.length / 1_000_000) MB)")
        let r = await downloader.download(urlPath: side.originalURLPath, to: sideDest, expectedSize: max(0, head.length)) { _ in }
        if case .saved(let url) = r { stampDates(url, f) }
    }

    /// Give the file its capture time, so Finder and editors sort it where it was shot.
    private func stampDates(_ url: URL, _ f: CameraFile) {
        guard let date = f.captureDate else { return }
        try? FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
    }
}

// =========================================================================================
// MARK: Camera control
// =========================================================================================

extension AppModel {
    /// Switch tabs. Leaving Live (to Files or Webcam) always goes back through playback first; entering
    /// it needs a connected Pocket-family camera and no downloads running.
    func setWorkspace(_ w: Workspace) {
        guard w != workspace, !switchingWorkspace, screen != .connecting else { return }
        if workspace == .camera && (status.recording || controlBusy) {
            controlError = String(localized: "Stop recording before leaving Live.")
            return
        }
        if w == .camera {
            guard screen == .library, !linkLost, session != nil, target?.model.supportsLive == true else { return }
            if transfer != nil {
                controlError = String(localized: "Finish or cancel the downloads before using the camera.")
                return
            }
        }
        controlError = nil
        switchingWorkspace = true
        Task {
            defer { switchingWorkspace = false }
            if sessionInControl && w != .camera { await leaveLive() }
            if w == .camera { await enterLive() } else { workspace = w }
        }
    }

    private func enterLive() async {
        guard let s = session else { return }
        let gen = connectGeneration
        selection = []
        log("control: entering camera mode")
        guard await s.enterControl() else {
            if gen == connectGeneration { controlError = String(localized: "The camera didn’t switch to capture mode.") }
            return
        }
        guard gen == connectGeneration, session === s else { return }
        sessionInControl = true
        workspace = .camera
        await startLiveView(s)
    }

    /// Back to playback: stop the picture, relist the newest page (clips recorded meanwhile) and let
    /// the paging carry on where it was. If playback can't be restored, recover like a lost link.
    func leaveLive() async {
        guard let s = session, sessionInControl else { sessionInControl = false; return }
        let gen = connectGeneration
        log("control: back to the card")
        await s.stopLiveView()
        liveRenderer.reset()
        liveView = .off
        guard let page = await s.leaveControl() else {
            guard gen == connectGeneration, session === s else { return }
            log("control: couldn't return to playback — recovering the link")
            sessionInControl = false
            linkLost = true
            if !recovering { recoverTask = Task { await recoverLink() } }
            return
        }
        guard gen == connectGeneration, session === s else { return }
        sessionInControl = false
        let resolved = await http.resolveStorage(page.files, singleSdStorage: s.model.singleSdStorage)
        guard gen == connectGeneration, session === s else { return }
        let known = Set(files.map(\.id))
        let fresh = resolved.filter { !known.contains($0.id) }
        if !fresh.isEmpty {
            files = (fresh + files).sorted { $0.timestamp != $1.timestamp ? $0.timestamp > $1.timestamp : $0.seq > $1.seq }
            refreshDownloaded()
        }
        moreAvailable = moreAvailable || page.moreAvailable
        log("control: card relisted, \(fresh.count) new file(s), more=\(moreAvailable)")
        Task { await loadOlderWhileNew() }
    }

    /// The renderer's callbacks, set once (the render queue reads them).
    func configureLiveRenderer() {
        liveRenderer.onFirstFrame = {
            Task { @MainActor [weak self] in
                guard let self, self.workspace == .camera, self.liveView != .off else { return }
                self.liveView = .live  // also after an 18 s "unavailable": the picture wins
            }
        }
        liveRenderer.onNeedsKeyframe = {
            Task { @MainActor [weak self] in await self?.session?.requestKeyframe() }
        }
        liveRenderer.onDimensions = { size in
            guard size.width > 0, size.height > 0 else { return }
            Task { @MainActor [weak self] in self?.liveAspect = size.width / size.height }
        }
    }

    private func startLiveView(_ s: CameraSession) async {
        liveView = .starting
        liveRenderer.reset()
        liveStartToken += 1
        let token = liveStartToken
        let renderer = liveRenderer
        let ok = await s.startLiveView(
            onVideo: { renderer.enqueue(annexB: $0) },
            onDiscontinuity: { renderer.requireKeyframe() })
        if !ok, liveView == .starting { liveView = .unavailable; return }
        // The request and one fallback take up to ~16 s; past that, say so instead of waiting forever.
        Task {
            try? await Task.sleep(for: .seconds(18))
            guard token == liveStartToken, liveView == .starting, workspace == .camera else { return }
            liveView = .unavailable
            log("live: no picture after 18 s")
        }
    }

    func dismissControlError(_ message: String) {
        if controlError == message { controlError = nil }
    }

    /// The shutter key: start/stop recording in clip modes, one picture in photo modes.
    func pressShutter() {
        guard workspace == .camera, !controlBusy, let s = session else { return }
        let recording = status.recording
        // Only modes whose shutter command is known (the deck); stopping is always allowed.
        guard recording || status.captureMode.map(CaptureMode.deck.contains) ?? true else { return }
        let clip = status.captureMode?.records ?? true
        controlBusy = true
        controlError = nil
        Task {
            defer { controlBusy = false }
            let ok = clip ? await s.setRecording(!recording) : await s.takePhoto()
            log("control: shutter (\(clip ? (recording ? "stop" : "record") : "photo")) → \(ok ? "ok" : "refused")")
            if !ok { controlError = String(localized: "The camera didn’t accept the command.") }
        }
    }

    func setMode(_ mode: CaptureMode) {
        guard workspace == .camera, !controlBusy, !status.recording, status.captureMode != mode, let s = session else { return }
        controlBusy = true
        controlError = nil
        Task {
            defer { controlBusy = false }
            let ok = await s.setMode(mode)
            log("control: mode \(mode) → \(ok ? "ok" : "refused")")
            if !ok { controlError = String(localized: "The camera didn’t change mode.") }
        }
    }
}
