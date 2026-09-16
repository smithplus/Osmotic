import Foundation
import OsmoticCore

// =========================================================================================
// MARK: Disconnect
// =========================================================================================

extension AppModel {
    func requestDisconnect() {
        // A card has nothing to release: leave the library, keep the volume mounted.
        if isCard {
            closeCard()
            return
        }
        if transfer != nil && screen == .library { confirmingDisconnect = true } else { Task { await disconnect() } }
    }

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
    func cleanup(restoreWifi: Bool) async {
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

    /// Wi-Fi work that must finish before the app quits: a connect, a recovery or a teardown still
    /// running, or a camera network joined and not yet handed back.
    var hasWifiWorkPending: Bool {
        [connectTask, recoverTask, teardownTask, startupRecovery].contains { $0 != nil }
            || Preferences.pendingCameraSSID != nil
    }

    /// Wait for any Wi-Fi restore still running (quitting), including the cleanup of a connect
    /// attempt that was just cancelled — it runs in that attempt's task.
    func finishWifiWork() async {
        for work in [connectTask, recoverTask, teardownTask, startupRecovery] { await work?.value }
        await teardownTask?.value  // the cancelled attempt's cleanup may have replaced it meanwhile
    }

    // MARK: Link recovery

    func handleLinkLost(from s: CameraSession) {
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

    func handleLinkRestored(from s: CameraSession) {
        guard linkLost, session === s else { return }
        linkLost = false
        log("library: camera link restored")
        // The same session came back while out of playback: put it back into playback for the card.
        if sessionInControl { Task { await leaveLive() } }
    }

    /// The camera went quiet: rejoin its AP if the Mac left it, and re-register a fresh session if
    /// the old one doesn't come back by itself. The file list stays as it is.
    func recoverLink() async {
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
                let resolved = await http.resolveStorage(result.files, singleSdStorage: result.model.singleSdStorage)
                guard gen == connectGeneration, session === s else { return }
                let (merged, fresh) = files.merging(resolved)
                if !fresh.isEmpty {
                    files = merged
                    refreshDownloaded(adding: fresh)
                }
                moreAvailable = moreAvailable || result.moreAvailable
                log("recover: session re-established (\(fresh.count) new file(s))")
                probeRealSizes()
                return
            }
            session = nil
            await s.close()
        }
        log("recover: gave up after 3 attempts")
        if stillWanted() { linkGaveUp = true }
    }

    /// Wait (bounded) for the link to come back — used by the transfer loop before retrying a file.
    func waitForLink(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !linkLost && !reconnecting { return true }
            if Task.isCancelled || screen != .library || linkGaveUp { return false }
            try? await Task.sleep(for: .seconds(1))
        }
        return !linkLost
    }

    // MARK: Startup recovery

    /// A previous run that died while on the camera's AP left a marker; put the Wi-Fi back.
    func recoverInterruptedSession() async {
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
}
