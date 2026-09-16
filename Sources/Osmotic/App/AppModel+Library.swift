import AppKit
import Foundation
import OsmoticCore

// =========================================================================================
// MARK: Library
// =========================================================================================

extension AppModel {
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

    /// New files not already on their way.
    var newNotQueued: [CameraFile] {
        let q = queuedIds
        return newFiles.filter { !q.contains($0.id) }
    }

    func isDownloaded(_ f: CameraFile) -> Bool { downloaded.contains(f.id) }

    func isOnDisk(_ f: CameraFile) -> Bool { FileManager.default.fileExists(atPath: DownloadPaths.destination(for: f).path) }

    /// Which files are already on the Mac. `adding` checks only newly listed files (a page of 45 on a
    /// card of thousands shouldn't re-check the disk for every file already known).
    func refreshDownloaded(adding added: [CameraFile]? = nil) {
        let fm = FileManager.default
        let onMac: (CameraFile) -> Bool = { f in
            self.history.contains(f) || fm.fileExists(atPath: DownloadPaths.destination(for: f).path)
        }
        if let added {
            let hits = added.filter(onMac).map(\.id)
            if !hits.isEmpty { downloaded.formUnion(hits) }
        } else {
            downloaded = Set(files.filter(onMac).map(\.id))
        }
        probeRealSizes()
    }

    /// The size to show and to count on: the server's when known, else the manifest's.
    func size(of f: CameraFile) -> Int { realSizes[f.id] ?? f.sizeBytes }

    /// One HEAD per clip whose listed size can't be trusted: videos over two minutes (4 GiB is about
    /// four minutes of 4K at the Pocket 3's top bitrate) and files listed without a size.
    func probeRealSizes() {
        let candidates = files.filter { f in
            !sizeProbed.contains(f.id) && f.isVideo && (f.durationSec >= 120 || f.sizeBytes <= 0)
        }
        guard !candidates.isEmpty, let s = session else { return }
        sizeProbed.formUnion(candidates.map(\.id))
        Task { [weak self] in
            for (i, f) in candidates.enumerated() {
                guard let self else { return }
                guard self.session === s, !self.sessionInControl else {
                    // Left for Live or lost the session: the rest get probed on the next refresh.
                    self.sizeProbed.subtract(candidates[i...].map(\.id))
                    return
                }
                guard let head = await self.http.headStatus(f.originalURLPath), head.status == 200, head.length > 0
                else { self.sizeProbed.remove(f.id); continue }
                guard self.session === s, head.length != self.size(of: f) else { continue }
                let before = self.size(of: f)
                self.realSizes[f.id] = head.length
                if var t = self.transfer {
                    if t.current?.id == f.id {
                        // Downloading now: move both, so `transferRealSize` sees no difference later.
                        t.bytesTotal += head.length - t.currentSize
                        t.currentSize = head.length
                    } else if self.queue.contains(where: { $0.id == f.id }) {
                        t.bytesTotal += head.length - max(0, before)  // queued, not started
                    }
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
        let (merged, added) = files.merging(resolved, pageIsOlder: true)
        files = merged
        moreAvailable = page.moreAvailable
        refreshDownloaded(adding: added)
        let fresh = added.filter { !downloaded.contains($0.id) }.count
        log("library: +\(added.count) older files (\(fresh) not downloaded), more=\(moreAvailable)")
        return fresh
    }

    /// New footage sits at the top of the card, so keep paging back while pages still bring files that
    /// aren't on the Mac — "Download New" then covers a whole trip, not just the newest 45.
    func loadOlderWhileNew() async {
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
        if isCard { return await cardThumbnail(for: f) }
        guard let data = await thumbnails.thumbnail(for: f), let img = NSImage(data: data) else { return nil }
        cacheThumbnail(img, for: f.id)
        return img
    }

    func cachedThumbnail(for f: CameraFile) -> NSImage? { thumbCache.object(forKey: f.id as NSString) }

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
}
