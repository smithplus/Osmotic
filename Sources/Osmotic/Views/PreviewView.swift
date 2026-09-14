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

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let player {
                    PlayerView(player: player)
                } else if let photo {
                    Image(nsImage: photo).resizable().scaledToFit()
                } else if failed {
                    ContentUnavailableView("No se pudo abrir la vista previa", systemImage: "eye.slash",
                                           description: Text("Descargalo para verlo en calidad completa."))
                        .foregroundStyle(.white)
                } else {
                    ProgressView().controlSize(.large).tint(.white)
                }
            }
            .frame(minWidth: 720, minHeight: 405)

            HStack(spacing: Theme.s3) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name).font(.headline).lineLimit(1).truncationMode(.middle)
                    Text(info).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if model.isDownloaded(file) {
                    Button("Mostrar en Finder") { model.revealInFinder(file) }
                } else {
                    Button("Descargar") { model.enqueue([file]); dismiss() }
                        .buttonStyle(.borderedProminent)
                }
                Button("Cerrar") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(Theme.s3)
        }
        .task { await load() }
        .onDisappear { player?.pause() }
    }

    private var info: String {
        var parts: [String] = []
        if let d = file.captureDate { parts.append(Format.dayHeader.string(from: d) + " " + Format.time.string(from: d)) }
        if let r = file.resolution { parts.append(r) }
        if let fps = file.resLabel { parts.append(fps) }
        if file.durationSec > 0 { parts.append(Format.duration(file.durationSec)) }
        if file.sizeBytes > 0 { parts.append(Format.bytes(file.sizeBytes)) }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        if file.isVideo {
            for path in file.previewURLPaths {
                let url = model.http.url(path)
                // The proxy is an MP4 behind a `.LRF` name that lighttpd serves untyped.
                let asset = AVURLAsset(url: url, options: [AVURLAssetOverrideMIMETypeKey: "video/mp4"])
                if (try? await asset.load(.isPlayable)) == true {
                    log("preview: streaming \(path)")
                    let p = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                    player = p
                    p.play()
                    return
                }
                log("preview: \(path) not playable")
            }
            failed = true
        } else {
            if let thumb = model.cachedThumbnail(for: file) { photo = thumb }
            if let data = await model.http.data(file.originalURLPath), let img = NSImage(data: data) {
                photo = img
            } else if photo == nil {
                failed = true
            }
        }
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
