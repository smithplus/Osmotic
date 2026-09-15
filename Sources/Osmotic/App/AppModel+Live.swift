import Foundation
import OsmoticCore

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
        let (merged, fresh) = files.merging(resolved)
        if !fresh.isEmpty {
            files = merged
            refreshDownloaded(adding: fresh)
        }
        moreAvailable = moreAvailable || page.moreAvailable
        log("control: card relisted, \(fresh.count) new file(s), more=\(moreAvailable)")
        probeRealSizes()  // clips the probe skipped while Live was on
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
            if !ok { controlError = String(localized: "The camera didn’t accept the command. Try again.") }
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
            if !ok { controlError = String(localized: "The camera didn’t change mode. Try again, or change it on the camera.") }
        }
    }
}
