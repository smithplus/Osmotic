import Foundation
import OsmoticCore

// =========================================================================================
// MARK: Transfers
// =========================================================================================

extension AppModel {
    func downloadNew() { enqueue(newNotQueued) }

    func downloadSelected() { enqueue(selectedFiles) }

    func enqueue(_ list: [CameraFile]) {
        // Downloads need the camera in playback: never while Live is starting or running.
        guard !switchingWorkspace, !sessionInControl, workspace == .files else { return }
        let fresh = list.filter { !queuedIds.contains($0.id) }
        guard !fresh.isEmpty else { return }
        // Oldest first, so an interrupted run leaves a contiguous, dated set on disk.
        queue += fresh.oldestFirst()
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
            ok: false, text: String(localized: "Download canceled. What already arrived is saved."))
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
            ? TransferSummary(ok: false, text: String(localized: "Download canceled"))
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
