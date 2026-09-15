import AppKit
import Foundation
import OsmoticCore

// =========================================================================================
// MARK: Demo
// =========================================================================================

extension AppModel {
    /// UI demo without hardware: a captured manifest on screen, or the connection stepper mid-way.
    /// `OSMOTIC_DEMO_MANIFEST=<file.bin> [OSMOTIC_DEMO_SCREEN=connecting|cameras|camera|webcam] [OSMOTIC_DEMO_THUMBS=<dir>]`.
    /// The landing's demo video (`scripts/make_demo_video.sh`) steps through one session with:
    /// `OSMOTIC_DEMO_STAGE=bluetooth|pairing|wifi|datalink` (connecting), and on the library
    /// `OSMOTIC_DEMO_SELECT=<n>` (clips ticked, default 2), `OSMOTIC_DEMO_PROGRESS=none|<0…1>` (the
    /// download of those clips) and `OSMOTIC_DEMO_DONE=1` (they arrived); on the Live tab
    /// `OSMOTIC_DEMO_CAPTURE=video|photo|slowmo|lowlight` and `OSMOTIC_DEMO_REC=off|<seconds>`.
    func loadDemo(manifestPath: String, screen demoScreen: String?) {
        let env = ProcessInfo.processInfo.environment
        log("demo: \(manifestPath)")
        let bytes = (try? Data(contentsOf: URL(fileURLWithPath: manifestPath))).map { [UInt8]($0) } ?? []
        target = Target(id: UUID(), name: "OsmoPocket3-D1E9", model: CameraModel.resolve(modelId: 0x20, name: nil), modelId: 0x20)
        files = ManifestDecoder.inferMissingExtensions(ManifestDecoder.decodeBlob(bytes)).newestFirst()
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
            // The same lines the real connection shows at each stage.
            switch env["OSMOTIC_DEMO_STAGE"] {
            case "bluetooth":
                stage = .bluetooth
                stageDetail = String(localized: "Looking for \(target?.name ?? "")…")
            case "pairing":
                stage = .pairing
                stageDetail = String(localized: "Pairing with the camera…")
            case "wifi":
                stage = .wifi
                stageDetail = String(localized: "Waiting for the camera to turn on its Wi-Fi…")
            case "datalink":
                stage = .datalink
                stageDetail = String(localized: "Reading the camera’s card…")
                datalinkProgress = 0.6
            default:
                stage = .pairing
                needsApproval = true
                stageDetail = String(localized: "Approve the connection on the camera’s screen")
            }
        case "webcam":
            screen = .cameras
            workspace = .webcam
        case "camera":
            screen = .library
            workspace = .camera
            liveView = .live
            var st = status
            let modes: [String: CaptureMode] = ["video": .video, "photo": .photo, "slowmo": .slowMotion, "lowlight": .lowLight]
            st.captureMode = modes[env["OSMOTIC_DEMO_CAPTURE"] ?? ""] ?? .video
            // `OSMOTIC_DEMO_REC=off` shows it idle; a number is the seconds recorded so far.
            let rec = env["OSMOTIC_DEMO_REC"]
            st.recording = rec != "off"
            st.recordingSeconds = Int(rec ?? "") ?? 754
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
            let count = min(max(0, Int(env["OSMOTIC_DEMO_SELECT"] ?? "") ?? 2), max(0, files.count - 1))
            let picked = Array(files.dropFirst().prefix(count))
            selection = Set(picked.map(\.id))
            if env["OSMOTIC_DEMO_DONE"] == "1" {
                downloaded.formUnion(picked.map(\.id))
                selection = []
                let folderName = Preferences.downloadFolder.lastPathComponent
                lastTransferSummary = TransferSummary(
                    ok: true, text: String(localized: "Done: \(String(localized: "\(picked.count) files")) in \(folderName)"))
            } else if let raw = env["OSMOTIC_DEMO_PROGRESS"] {
                if let fraction = Double(raw), !picked.isEmpty { demoTransfer(of: picked, at: min(1, max(0, fraction))) }
            } else if let clip = files.first(where: \.isVideo) {
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

    /// A download of `picked`, `fraction` of the way through, laid out as the real queue would be:
    /// the finished files, the one on the wire and the ones still waiting.
    private func demoTransfer(of picked: [CameraFile], at fraction: Double) {
        let sizes = picked.map { max(1, $0.sizeBytes) }
        let totalBytes = sizes.reduce(0, +)
        let target = Int(Double(totalBytes) * fraction)
        var t = TransferState(total: picked.count, bytesTotal: totalBytes)
        var before = 0
        for (i, file) in picked.enumerated() {
            if target < before + sizes[i] || i == picked.count - 1 {
                t.done = i
                t.bytesDone = before
                t.current = file
                t.currentSize = sizes[i]
                t.currentBytes = min(sizes[i], target - before)
                currentTransferId = file.id
                queuedIds = Set(picked[i...].map(\.id))
                downloaded.formUnion(picked[..<i].map(\.id))
                break
            }
            before += sizes[i]
        }
        t.speed = 32_400_000
        transfer = t
    }
}
