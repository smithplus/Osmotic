import AppKit
import Foundation
import Observation
import OsmoticCore
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
            case .bluetooth: "Bluetooth"
            case .pairing: "Emparejamiento"
            case .wifi: "Wi-Fi de la cámara"
            case .datalink: "Enlace con la cámara"
            case .library: "Biblioteca"
            }
        }
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all = "Todo", videos = "Videos", photos = "Fotos", favorites = "Favoritos", new = "Nuevos"
        var id: String { rawValue }
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

    // ---- transfers ----------------------------------------------------------------------------
    private(set) var transfer: TransferState?
    private(set) var lastTransferSummary: String?

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
    @ObservationIgnored private var thumbCache: [String: NSImage] = [:]
    @ObservationIgnored private var connectGeneration = 0
    @ObservationIgnored private var cameraPassword: String?
    @ObservationIgnored private var recovering = false
    @ObservationIgnored private var cameraSideIP: String?
    @ObservationIgnored private var transferGeneration = 0
    private(set) var reconnecting = false

    static var thumbnailCacheDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("io.github.smithplus.osmotic/thumbs", isDirectory: true)
    }

    init() {
        log("Osmotic \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev") — log file \(logSink.url.path)")
        if let demo = ProcessInfo.processInfo.environment["OSMOTIC_DEMO_MANIFEST"] {
            loadDemo(manifestPath: demo, screen: ProcessInfo.processInfo.environment["OSMOTIC_DEMO_SCREEN"])
            return
        }
        ble.startScan()
        Task { await self.recoverInterruptedSession() }
    }

    /// UI demo without hardware: a captured manifest on screen, or the connection stepper mid-way.
    /// `OSMOTIC_DEMO_MANIFEST=<file.bin> [OSMOTIC_DEMO_SCREEN=connecting|cameras]`.
    private func loadDemo(manifestPath: String, screen demoScreen: String?) {
        log("demo: \(manifestPath)")
        let bytes = (try? Data(contentsOf: URL(fileURLWithPath: manifestPath))).map { [UInt8]($0) } ?? []
        target = Target(id: UUID(), name: "OsmoPocket3-D1E9", model: CameraModel.resolve(modelId: 0x20, name: nil), modelId: 0x20)
        files = ManifestDecoder.inferMissingExtensions(ManifestDecoder.decodeBlob(bytes)).sorted { $0.timestamp != $1.timestamp ? $0.timestamp > $1.timestamp : $0.seq > $1.seq }
        var st = CameraStatus()
        st.batteryPercent = 76
        st.sdTotalMb = 121_785
        st.sdFreeMb = 68_131
        status = st
        moreAvailable = false
        refreshDownloaded()
        if let dir = ProcessInfo.processInfo.environment["OSMOTIC_DEMO_THUMBS"],
           let names = try? FileManager.default.contentsOfDirectory(atPath: dir).filter({ $0.hasSuffix(".jpg") }).sorted(),
           !names.isEmpty {
            for (i, f) in files.enumerated() {
                thumbCache[f.id] = NSImage(contentsOfFile: dir + "/" + names[i % names.count])
            }
        }
        switch demoScreen {
        case "connecting":
            screen = .connecting
            stage = .pairing
            needsApproval = true
            stageDetail = "Aprobá la conexión en la pantalla de la cámara"
        case "cameras":
            screen = .cameras
            ble.injectDemo(DiscoveredCamera(id: UUID(), name: "OsmoPocket3-8B1D", rssi: -41, modelId: 0x20,
                                            model: CameraModel.resolve(modelId: 0x20, name: nil), brand: .dji, lastSeen: Date()))
        default:
            screen = .library
            if let first = files.first { downloaded.insert(first.id) }
            if files.count > 3 { selection = [files[1].id, files[2].id] }
            if let clip = files.first(where: \.isVideo) {
                var t = TransferState(total: 4, bytesTotal: 2_070_000_000)
                t.done = 1
                t.current = clip
                t.currentSize = clip.sizeBytes
                t.currentBytes = clip.sizeBytes / 3
                t.bytesDone = 600_000_000
                t.speed = 32_400_000
                transfer = t
            }
        }
    }

    var savedCameras: [SavedCamera] { SavedCameraStore.all() }

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
        stage = .bluetooth
        stageDetail = "Buscando \(t.name)…"
        datalinkProgress = 0
        screen = .connecting
        ble.stopScan()
        LocalNetworkPermission.prime()
        log("=== connect \(t.name) [\(t.model.name)] port=\(t.model.datalinkPort) poke=\(t.model.tcpPoke) ===")
        connectGeneration += 1
        let gen = connectGeneration
        let previous = connectTask
        connectTask = Task { [weak self] in
            // A cancelled attempt cleans up after itself; never overlap it with the next one.
            await previous?.value
            guard let self, self.connectGeneration == gen else { return }
            await self.runConnect(t, generation: gen)
        }
    }

    func cancelConnect() {
        log("connect: cancelled by user")
        connectGeneration += 1
        connectTask?.cancel()
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
        do {
            // Remember where the Mac's Wi-Fi was, to return there afterwards.
            if location.isUndetermined { await location.request() }
            try live()
            previousSSID = WiFiService.currentSSID()
            if let stale = Preferences.pendingCameraSSID, previousSSID == stale { previousSSID = Preferences.pendingRestoreSSID }
            log("wifi: current network \(previousSSID.map { "\"\($0)\"" } ?? "unknown (no Location permission or not on Wi-Fi)")")

            // 1. Bluetooth + pairing → the camera's own Wi-Fi credentials.
            let (ssid, password) = try await pairAndGetCredentials(t)
            try live()
            SavedCameraStore.setPassword(password, for: t.id)
            cameraPassword = password
            // Already sitting on the camera's AP (a previous run)? Then that is not "home".
            if previousSSID == ssid { previousSSID = nil }

            // 2. Join the camera's access point.
            stage = .wifi
            stageDetail = "Esperando que la cámara encienda su Wi-Fi…"
            Preferences.pendingRestoreSSID = previousSSID
            Preferences.pendingCameraSSID = ssid
            joinedCameraSSID = ssid
            try await Task.sleep(for: .seconds(3))
            let joined = try await WiFiService.join(ssid: ssid, password: password, timeout: 75) { text in
                Task { @MainActor [weak self] in self?.stageDetail = text }
            }
            cameraSideIP = joined.ip
            try live()

            // 3. Datalink: register, playback, newest page.
            stage = .datalink
            stageDetail = "Leyendo la tarjeta de la cámara…"
            let s = makeSession(model: t.model, interface: joined.interface)
            s.onProgress = { p in Task { @MainActor [weak self] in self?.datalinkProgress = p } }
            session = s   // owned from here on: teardown closes it on any exit
            let result = await s.connect()
            try live()
            guard result.handshakeOk else {
                throw ConnectError.message("La cámara no respondió en el enlace de datos. Si macOS preguntó por acceso a la red local, permitilo y reintentá.")
            }

            // 4. Library.
            stage = .library
            stageDetail = result.files.isEmpty ? "La tarjeta está vacía" : "\(result.files.count) archivos"
            let resolved = await http.resolveStorage(result.files, singleSdStorage: result.model.singleSdStorage)
            try live()
            files = resolved
            moreAvailable = result.moreAvailable
            refreshDownloaded()
            SavedCameraStore.save(SavedCamera(id: t.id, bleName: t.name, modelId: t.modelId,
                                              modelName: result.model.name, lastConnected: Date()))
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
        s.onLinkLost = { Task { @MainActor [weak self] in self?.handleLinkLost(from: s) } }
        s.onLinkRestored = { Task { @MainActor [weak self] in self?.handleLinkRestored(from: s) } }
        return s
    }

    enum ConnectError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let m) = self { m } else { nil } }
    }

    private func pairAndGetCredentials(_ t: Target) async throws -> (String, String) {
        guard ble.power == .poweredOn else {
            throw ConnectError.message(ble.power == .unauthorized
                ? "Osmotic no tiene permiso de Bluetooth. Activalo en Ajustes del Sistema › Privacidad y seguridad › Bluetooth."
                : "El Bluetooth del Mac está apagado.")
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
            self.stageDetail = "Emparejando con la cámara…"
            self.isArmed = true
            self.armed?.resume()
            self.armed = nil
            self.flow?.onReady()
        }
        ble.onDisconnect = { [weak self] error in
            guard let self, self.stage <= .pairing, self.screen == .connecting else { return }
            self.failPending(ConnectError.message("La cámara cerró la conexión Bluetooth\(error.map { " (\($0.localizedDescription))" } ?? "")."))
        }

        isArmed = false
        pendingCredentials = nil
        guard ble.connect(t.id) else {
            throw ConnectError.message("No se encuentra la cámara. Encendela y acercala al Mac.")
        }
        // Bluetooth link + GATT armed.
        try await withTimeout(25, message: "No se pudo conectar por Bluetooth. ¿La cámara está encendida y cerca?") { [self] in
            if isArmed { return }
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in armed = c }
        }
        // Pairing → credentials. Approval on the camera screen can take a while.
        return try await withTimeout(120, message: "La cámara no entregó su Wi-Fi. Probá apagarla y encenderla.") { [self] in
            if let p = pendingCredentials { return (p.ssid, p.password) }
            let c = try await withCheckedThrowingContinuation { (c: CheckedContinuation<(ssid: String, password: String), Error>) in
                credentials = c
            }
            return (c.ssid, c.password)
        }
    }

    private func handlePairing(_ event: PairingFlow.Event) {
        switch event {
        case .approvalRequired:
            needsApproval = true
            stageDetail = "Aprobá la conexión en la pantalla de la cámara"
        case .paired:
            needsApproval = false
            stageDetail = "Pidiendo la red Wi-Fi a la cámara…"
        case .credentials(let ssid, let password):
            passwordPromptSSID = nil
            if let c = credentials {
                c.resume(returning: (ssid, password))
                credentials = nil
            } else {
                pendingCredentials = (ssid, password)
            }
        case .needsPassword(let ssid):
            stageDetail = "Ingresá la contraseña Wi-Fi de la cámara"
            passwordPromptSSID = ssid
        case .notActivated:
            failPending(ConnectError.message("Esta cámara nunca fue activada, así que no enciende su Wi-Fi. Activala una vez con DJI Mimo."))
        }
    }

    func providePassword(_ password: String) {
        passwordPromptSSID = nil
        flow?.providePassword(password)
    }

    private func failPending(_ error: Error) {
        armed?.resume(throwing: error)
        armed = nil
        credentials?.resume(throwing: error)
        credentials = nil
    }

    /// Run `body`, failing with `message` if it takes longer than `seconds`.
    private func withTimeout<T: Sendable>(_ seconds: Double, message: String,
                                          _ body: @escaping @MainActor () async throws -> T) async throws -> T {
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

    func disconnect() async {
        log("=== disconnect ===")
        transferGeneration += 1
        transferTask?.cancel()
        transferTask = nil
        queue.removeAll()
        transfer = nil
        connectGeneration += 1
        files = []
        selection = []
        status = CameraStatus()
        linkLost = false
        screen = .cameras
        await cleanup(restoreWifi: Preferences.restoreWifi)
        ble.startScan()
    }

    /// Teardown in a task of its own, so a cancelled caller (a cancelled connect, the transfer queue
    /// that asked for "disconnect when done") can't cut the Wi-Fi restore short.
    private func cleanup(restoreWifi: Bool) async {
        await Task { @MainActor in await self.teardown(restoreWifi: restoreWifi) }.value
    }

    private func teardown(restoreWifi: Bool) async {
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
                stageDetail = "Volviendo a tu Wi-Fi…"
                await WiFiService.restore(previous: previousSSID, cameraSSID: cam, cameraSideIP: cameraSideIP)
                restoringWifi = false
            }
        }
        cameraPassword = nil
        cameraSideIP = nil
        Preferences.pendingRestoreSSID = nil
        Preferences.pendingCameraSSID = nil
    }

    func backToCameras() {
        connectError = nil
        screen = .cameras
        ble.startScan()
    }

    func retry() {
        guard let t = target else { return }
        connectError = nil
        start(t)
    }

    private func handleLinkLost(from s: CameraSession) {
        guard screen == .library, session === s else { return }   // ignore a replaced session's last words
        linkLost = true
        log("library: camera link lost — trying to recover")
        Task { await recoverLink() }
    }

    private func handleLinkRestored(from s: CameraSession) {
        guard linkLost, session === s else { return }
        linkLost = false
        log("library: camera link restored")
    }

    /// The camera went quiet: rejoin its AP if the Mac left it, and re-register a fresh session if
    /// the old one doesn't come back by itself. The file list stays as it is.
    private func recoverLink() async {
        guard !recovering, let t = target, let ssid = joinedCameraSSID, let pass = cameraPassword else { return }
        recovering = true
        reconnecting = true
        defer { recovering = false; reconnecting = false }
        let gen = connectGeneration
        func stillWanted() -> Bool { screen == .library && gen == connectGeneration && linkLost }
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
            let s = makeSession(model: t.model, interface: iface)
            session = s
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
                if !fresh.isEmpty {
                    files = (fresh + files).sorted { $0.timestamp != $1.timestamp ? $0.timestamp > $1.timestamp : $0.seq > $1.seq }
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
    }

    /// Wait (bounded) for the link to come back — used by the transfer loop before retrying a file.
    private func waitForLink(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !linkLost && !reconnecting { return true }
            if Task.isCancelled || screen != .library { return false }
            try? await Task.sleep(for: .seconds(1))
        }
        return !linkLost
    }

    /// A previous run that died while on the camera's AP left a marker; put the Wi-Fi back.
    private func recoverInterruptedSession() async {
        guard let cam = Preferences.pendingCameraSSID else { return }
        let current = WiFiService.currentSSID()
        let onCamera: Bool
        if let current { onCamera = current == cam } else { onCamera = await WiFiService.isCameraReachable() }
        if onCamera {
            log("wifi: recovering from an interrupted session on \(cam)")
            restoringWifi = true
            await WiFiService.restore(previous: Preferences.pendingRestoreSSID, cameraSSID: cam, cameraSideIP: nil)
            restoringWifi = false
        }
        Preferences.pendingRestoreSSID = nil
        Preferences.pendingCameraSSID = nil
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

    func isDownloaded(_ f: CameraFile) -> Bool { downloaded.contains(f.id) }

    func isOnDisk(_ f: CameraFile) -> Bool { FileManager.default.fileExists(atPath: DownloadPaths.destination(for: f).path) }

    private func refreshDownloaded() {
        let fm = FileManager.default
        downloaded = Set(files.filter { f in
            history.contains(f) || fm.fileExists(atPath: DownloadPaths.destination(for: f).path)
        }.map(\.id))
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
    /// aren't on the Mac — "Descargar nuevos" then covers a whole trip, not just the newest 45.
    private func loadOlderWhileNew() async {
        var pages = 0
        while screen == .library, moreAvailable, pages < 40 {
            let newOnTop = files.isEmpty || !newFiles.isEmpty
            guard newOnTop else { break }
            if await loadOlderPage() == 0 { break }
            pages += 1
        }
    }

    func thumbnail(for f: CameraFile) async -> NSImage? {
        if let img = thumbCache[f.id] { return img }
        guard let data = await thumbnails.thumbnail(for: f), let img = NSImage(data: data) else { return nil }
        thumbCache[f.id] = img
        return img
    }

    func cachedThumbnail(for f: CameraFile) -> NSImage? { thumbCache[f.id] }

    @ObservationIgnored private var selectionAnchor: String?

    /// A click on a cell, Finder-style: plain selects just this one (again to clear), ⌘ adds or
    /// removes it, ⇧ selects the range from the last clicked file.
    func click(_ f: CameraFile, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.shift), let anchor = selectionAnchor,
           let a = visibleFiles.firstIndex(where: { $0.id == anchor }),
           let b = visibleFiles.firstIndex(where: { $0.id == f.id }) {
            selection.formUnion(visibleFiles[min(a, b)...max(a, b)].map(\.id))
            return
        }
        if modifiers.contains(.command) {
            toggleInSelection(f)
            return
        }
        selection = selection == [f.id] ? [] : [f.id]
        selectionAnchor = f.id
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
        var speed: Double = 0       // bytes/s, smoothed
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

    func downloadNew() { enqueue(newFiles) }

    func downloadSelected() { enqueue(selectedFiles) }

    func enqueue(_ list: [CameraFile]) {
        let queuedIds = Set(queue.map(\.id)).union(transfer?.current.map { [$0.id] } ?? [])
        let fresh = list.filter { !queuedIds.contains($0.id) }
        guard !fresh.isEmpty else { return }
        // Oldest first, so an interrupted run leaves a contiguous, dated set on disk.
        queue += fresh.sorted { $0.timestamp != $1.timestamp ? $0.timestamp < $1.timestamp : $0.seq < $1.seq }
        let bytes = fresh.reduce(0) { $0 + max(0, $1.sizeBytes) }
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
            transferTask = Task { [weak self] in
                await self?.runQueue(generation: gen)
                if self?.transferGeneration == gen { self?.transferTask = nil }
            }
        }
    }

    func cancelTransfers() {
        log("transfer: cancelled by user")
        transferGeneration += 1
        queue.removeAll()
        transferTask?.cancel()
        transferTask = nil
        transfer = nil
        lastTransferSummary = "Descarga cancelada — lo que ya bajó quedó guardado"
    }

    private func runQueue(generation gen: Int) async {
        var saved = 0
        func current() -> Bool { gen == transferGeneration && !Task.isCancelled }
        while current(), !queue.isEmpty {
            let f = queue.removeFirst()
            transfer?.current = f
            transfer?.currentBytes = 0
            transfer?.currentSize = f.sizeBytes
            let dest = DownloadPaths.destination(for: f)
            log("transfer: \(f.name) → \(dest.path)")
            speedSample = (Date(), 0)
            let result = await downloader.download(urlPath: f.originalURLPath, to: dest, expectedSize: f.sizeBytes) { bytes in
                Task { @MainActor [weak self] in self?.transferProgress(fileId: f.id, bytes: bytes) }
            }
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
            case .failed(let why):
                transfer?.failed.append(f.name)
                log("transfer: \(f.name) FAILED — \(why)")
            case .cancelled:
                log("transfer: \(f.name) cancelled (partial kept for resume)")
            }
            guard gen == transferGeneration else { return }
            if var t = transfer {
                t.done += 1
                t.bytesDone += max(0, f.sizeBytes)
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
        lastTransferSummary = cancelled ? "Descarga cancelada"
            : failed.isEmpty ? "Listo: \(saved) archivo\(saved == 1 ? "" : "s") en \(Preferences.downloadFolder.lastPathComponent)"
            : "\(failed.count) archivo\(failed.count == 1 ? "" : "s") no se pudieron bajar — reintentá para reanudar"
        log("transfer: finished — \(lastTransferSummary ?? "")")
        if !cancelled { TransferNotifier.finished(saved: saved, failed: failed.count, folder: Preferences.downloadFolder) }
        if !cancelled && failed.isEmpty && Preferences.disconnectWhenDone && screen == .library {
            // Not awaited: disconnect() cancels this very task.
            Task { @MainActor in await self.disconnect() }
        }
    }

    @ObservationIgnored private var speedSample = (time: Date(), bytes: 0)
    @ObservationIgnored private var retryCounts: [String: Int] = [:]

    private func transferProgress(fileId: String, bytes: Int) {
        guard var t = transfer, t.current?.id == fileId else { return }
        let now = Date()
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
        let sideDest = dest.deletingLastPathComponent().appendingPathComponent(side.name)
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
