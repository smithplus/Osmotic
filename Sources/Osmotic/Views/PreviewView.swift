import AVFoundation
import AVKit
import OsmoticCore
import SwiftUI

/// Quick look at a file straight off the camera: clips stream their low-res `.LRF` proxy (falling back
/// to the original), stills load the full JPEG.
struct PreviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let file: CameraFile

    @State private var player: AVPlayer?
    @State private var photo: NSImage?
    @State private var failed = false
    @State private var source = ""

    var body: some View {
        // The sheet stays up while ← / → swap the file, so follow the model's current one.
        let current = model.previewFile ?? file
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let player {
                    PlayerView(player: player)
                } else if let photo {
                    Image(nsImage: photo).resizable().scaledToFit()
                } else if failed {
                    ContentUnavailableView("Couldn’t open the preview", systemImage: "eye.slash",
                                           description: Text("Download it to watch it in full quality."))
                        .foregroundStyle(.white)
                } else {
                    ProgressView().controlSize(.large).tint(.white)
                }
            }
            .frame(minWidth: 760, minHeight: 428)

            HStack(spacing: Theme.s3) {
                Button { model.stepPreview(by: -1) } label: { Image(systemName: "chevron.left") }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .help("Previous (←)")
                Button { model.stepPreview(by: 1) } label: { Image(systemName: "chevron.right") }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .help("Next (→)")
                VStack(alignment: .leading, spacing: 2) {
                    Text(current.name).font(.headline).lineLimit(1).truncationMode(.middle)
                    Text(info(current)).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if model.isOnDisk(current) {
                    Button("Show in Finder") { model.revealInFinder(current) }
                } else {
                    Button("Download") { model.enqueue([current]) }
                        .buttonStyle(.borderedProminent)
                }
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(Theme.s3)
        }
        .task(id: current.id) { await load(current) }
        .onDisappear { player?.pause() }
    }

    private func info(_ f: CameraFile) -> String {
        var parts: [String] = []
        if let d = f.captureDate { parts.append(Format.dayHeader.string(from: d) + " " + Format.time.string(from: d)) }
        if let r = f.resolution { parts.append(r) }
        if let fps = f.resLabel { parts.append(fps) }
        if f.durationSec > 0 { parts.append(Format.duration(f.durationSec)) }
        if f.sizeBytes > 0 { parts.append(Format.bytes(f.sizeBytes)) }
        if !source.isEmpty { parts.append(source) }
        return parts.joined(separator: " · ")
    }

    private func load(_ f: CameraFile) async {
        player?.pause()
        player = nil
        photo = nil
        failed = false
        source = ""
        let local = DownloadPaths.destination(for: f)
        let onDisk = FileManager.default.fileExists(atPath: local.path)
        if f.isVideo {
            if onDisk {
                // Already on the Mac: the original, instantly and at full quality.
                start(AVPlayer(url: local), source: String(localized: "original on your Mac"))
                return
            }
            for path in f.previewURLPaths {
                let url = model.http.url(path)
                // The proxy is an MP4 behind a `.LRF` name that lighttpd serves untyped: without the
                // override AVFoundation refuses it (verified against a range-serving stand-in).
                let asset = AVURLAsset(url: url, options: [AVURLAssetOverrideMIMETypeKey: "video/mp4"])
                if (try? await asset.load(.isPlayable)) == true {
                    guard !Task.isCancelled else { return }
                    log("preview: streaming \(path)")
                    start(AVPlayer(playerItem: AVPlayerItem(asset: asset)),
                          source: path.hasSuffix(".LRF") ? String(localized: "lightweight preview") : String(localized: "original from the camera"))
                    return
                }
                log("preview: \(path) not playable")
            }
            if !Task.isCancelled { failed = true }
        } else {
            if let thumb = model.cachedThumbnail(for: f) { photo = thumb }
            let data = onDisk ? try? Data(contentsOf: local) : await model.http.data(f.originalURLPath)
            guard !Task.isCancelled else { return }
            if let data, let img = NSImage(data: data) {
                photo = img
                source = onDisk ? String(localized: "on your Mac") : String(localized: "from the camera")
            } else if photo == nil {
                failed = true
            }
        }
    }

    private func start(_ p: AVPlayer, source label: String) {
        source = label
        player = p
        p.play()
    }
}

private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .floating
        v.showsFullScreenToggleButton = true
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) { v.player = player }
}
