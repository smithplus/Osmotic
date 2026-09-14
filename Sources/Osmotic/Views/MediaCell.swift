import AppKit
import OsmoticCore
import SwiftUI

/// One file in the grid: the camera's own screennail, what it is at a glance, and whether it is
/// already on the Mac.
struct MediaCell: View {
    @Environment(AppModel.self) private var model
    let file: CameraFile
    @State private var image: NSImage?
    @State private var hovering = false

    private var selected: Bool { model.selection.contains(file.id) }
    private var downloaded: Bool { model.isDownloaded(file) }
    private var isCurrentTransfer: Bool { model.transfer?.current?.id == file.id }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            thumbnail
            meta
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.previewFile = file }
        .simultaneousGesture(TapGesture().onEnded {
            let flags = NSEvent.modifierFlags
            model.toggleSelection(file, extend: flags.contains(.command) || flags.contains(.shift))
        })
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Vista previa") { model.previewFile = file }
            Button(downloaded ? "Descargar de nuevo" : "Descargar") { model.enqueue([file]) }
            if downloaded {
                Button("Mostrar en Finder") { model.revealInFinder(file) }
            }
        }
        .task(id: file.id) {
            if let hit = model.cachedThumbnail(for: file) { image = hit; return }
            image = await model.thumbnail(for: file)
        }
    }

    private var thumbnail: some View {
        ZStack {
            Rectangle().fill(Color.secondary.opacity(0.12))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                Image(systemName: file.isVideo ? "video" : "photo")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.tertiary)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipped()
        .overlay(alignment: .bottomLeading) { kindBadge.padding(Theme.s2) }
        .overlay(alignment: .topTrailing) {
            if file.starred {
                Image(systemName: "heart.fill")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(.black.opacity(0.45), in: Circle())
                    .padding(Theme.s2)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if downloaded {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 17))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Theme.success)
                    .padding(Theme.s2)
                    .help("Ya está en tu carpeta de descargas")
            } else if isCurrentTransfer {
                ProgressView(value: currentFraction)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .padding(Theme.s2)
            }
        }
        .overlay(alignment: .topLeading) {
            if selected || hovering {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, selected ? Theme.accent : .black.opacity(0.35))
                    .shadow(radius: 2)
                    .padding(Theme.s2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous)
                .strokeBorder(selected ? Theme.accent : Theme.hairline.opacity(hovering ? 1 : 0.5), lineWidth: selected ? 3 : 1)
        )
        .scaleEffect(hovering && !selected ? 1.015 : 1)
        .animation(.snappy(duration: 0.15), value: hovering)
        .animation(.snappy(duration: 0.15), value: selected)
    }

    private var currentFraction: Double {
        guard let t = model.transfer, t.currentSize > 0 else { return 0 }
        return min(1, Double(t.currentBytes) / Double(t.currentSize))
    }

    @ViewBuilder private var kindBadge: some View {
        if file.isVideo {
            Label(file.durationSec > 0 ? Format.duration(file.durationSec) : "Video", systemImage: "play.fill")
                .font(.caption.weight(.semibold).monospacedDigit())
                .labelStyle(BadgeLabelStyle())
        } else if file.isPanorama {
            Label("Panorama", systemImage: "pano")
                .font(.caption.weight(.semibold))
                .labelStyle(BadgeLabelStyle())
        } else if file.isBurst {
            Label("Ráfaga", systemImage: "square.stack")
                .font(.caption.weight(.semibold))
                .labelStyle(BadgeLabelStyle())
        }
    }

    private var meta: some View {
        HStack(spacing: Theme.s2) {
            Text(file.captureDate.map { Format.time.string(from: $0) } ?? file.name)
                .font(.callout.weight(.medium).monospacedDigit())
            Text(details)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
    }

    private var details: String {
        var parts: [String] = []
        if let r = Format.resolutionLabel(file.resolution) {
            parts.append(file.resLabel.map { "\(r) \($0)" } ?? r)
        } else if let fps = file.resLabel {
            parts.append(fps)
        }
        if file.sizeBytes > 0 { parts.append(Format.bytes(file.sizeBytes)) }
        if !file.isVideo && !file.ext.isEmpty { parts.append(file.ext) }
        return parts.joined(separator: " · ")
    }
}

private struct BadgeLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.black.opacity(0.55), in: Capsule())
    }
}
