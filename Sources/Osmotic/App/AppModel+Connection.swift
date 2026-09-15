import Foundation
import OsmoticCore

// =========================================================================================
// MARK: Connect
// =========================================================================================

extension AppModel {
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

    func makeSession(model: CameraModel, interface: String) -> CameraSession {
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

    func backToCameras() {
        connectError = nil
        screen = .cameras
        ble.startScan()
    }

    func retry() {
        guard let t = target else { return }
        start(t)  // clears the error itself; `start` only runs while one is showing
    }
}
