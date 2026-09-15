import AppKit
import Foundation
import OsmoticCore

// =========================================================================================
// MARK: Demo
// =========================================================================================

extension AppModel {
    /// UI demo without hardware: a captured manifest on screen, or the connection stepper mid-way.
    /// `OSMOTIC_DEMO_MANIFEST=<file.bin> [OSMOTIC_DEMO_SCREEN=connecting|cameras|camera|webcam] [OSMOTIC_DEMO_THUMBS=<dir>]`.
    func loadDemo(manifestPath: String, screen demoScreen: String?) {
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
}
