import AVFoundation
import AVKit
import ImageIO
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
                        .accessibilityLabel(Text(verbatim: current.name))
                } else if failed {
                    ContentUnavailableView(
                        "Couldn’t open the preview", systemImage: "eye.slash",
                        description: Text("Download it to watch it in full quality.")
                    )
                    .foregroundStyle(.white)
                } else {
                    ProgressView().controlSize(.large).tint(.white)
                }
            }
            .frame(minWidth: 760, minHeight: 428)

            HStack(spacing: Theme.s3) {
                CassetteKeyBank {
                    Button {
                        model.stepPreview(by: -1)
                    } label: {
                        Image(systemName: "chevron.left").accessibilityLabel("Previous")
                    }
                    .buttonStyle(.secondaryKey)
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .help("Previous (←)")
                    Button {
                        model.stepPreview(by: 1)
                    } label: {
                        Image(systemName: "chevron.right").accessibilityLabel("Next")
                    }
                    .buttonStyle(.secondaryKey)
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .help("Next (→)")
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(current.name).font(Theme.readout(12.5, weight: .semibold)).foregroundStyle(Theme.ink)
                        .lineLimit(1).truncationMode(.middle)
                    Text(info(current)).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer()
                CassetteKeyBank {
                    if model.isOnDisk(current) {
                        Button("Show in Finder") { model.revealInFinder(current) }
                            .buttonStyle(.secondaryKey)
                    } else {
                        Button("Download") { model.enqueue([current]) }
                            .disabled(model.linkLost || !model.isConnected)
                            .buttonStyle(.primaryKey)
                    }
                    Button("Close") { dismiss() }
                        .buttonStyle(.secondaryKey)
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(Theme.s3)
            .background(AluminumPlate())
        }
        .task(id: current.id) { await load(current) }
        .onDisappear { player?.pause() }
    }

    private func info(_ f: CameraFile) -> String {
        var parts: [String] = []
        if let d = f.captureDate { parts.append(Format.dayAndTime.string(from: d)) }
        if let r = f.resolution { parts.append(r) }
        if let fps = f.resLabel { parts.append(fps) }
        if f.durationSec > 0 { parts.append(Format.duration(f.durationSec)) }
        if model.size(of: f) > 0 { parts.append(Format.bytes(model.size(of: f))) }
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
                    start(
                        AVPlayer(playerItem: AVPlayerItem(asset: asset)),
                        source: path.hasSuffix(".LRF")
                            ? String(localized: "lightweight preview") : String(localized: "original from the camera"))
                    return
                }
                log("preview: \(path) not playable")
            }
            if !Task.isCancelled { failed = true }
        } else {
            if let thumb = model.cachedThumbnail(for: f) { photo = thumb }
            let data: Data? =
                onDisk
                ? await Task.detached { try? Data(contentsOf: local) }.value
                : await model.http.data(f.originalURLPath, limit: 128 << 20)  // a 48 MP JPEG or RAW-size still
            guard !Task.isCancelled else { return }
            // Decode off the main thread, at the sheet's size (a 48 MP still decoded whole is ~200 MB).
            let scaled: CGImage? = await Task.detached { data.flatMap { previewImage($0, maxPixel: 2400) } }.value
            guard !Task.isCancelled else { return }
            if let scaled {
                photo = NSImage(cgImage: scaled, size: NSSize(width: scaled.width, height: scaled.height))
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

/// A still decoded no larger than `maxPixel` on its longer side, honouring EXIF orientation.
nonisolated private func previewImage(_ data: Data, maxPixel: Int) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        kCGImageSourceCreateThumbnailWithTransform: true,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
}
