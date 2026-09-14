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
        // One gesture for both: selection responds on the first click with no double-click delay,
        // and the second click of a double-click opens the preview. The buttons on the thumbnail
        // take precedence over this, so ticking the circle never also re-selects the cell.
        .gesture(TapGesture().onEnded {
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                model.previewFile = file
            } else {
                model.click(file, modifiers: NSEvent.modifierFlags)
            }
        })
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Vista previa") { model.previewFile = file }
            if model.isOnDisk(file) {
                Button("Mostrar en Finder") { model.revealInFinder(file) }
            } else {
                // Also offered for files the history remembers but that were moved or deleted.
                Button("Descargar") { model.enqueue([file]) }
            }
        }
        .task(id: file.id) {
            if let hit = model.cachedThumbnail(for: file) { image = hit; return }
            image = await model.thumbnail(for: file)
        }
    }

    private var thumbnail: some View {
        ZStack {
            Rectangle().fill(Theme.well)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                Image(systemName: file.isVideo ? "video" : "photo")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(Theme.muted.opacity(0.6))
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipped()
        .overlay(alignment: .bottomLeading) { kindBadge.padding(Theme.s2) }
        .overlay(alignment: .topTrailing) {
            if file.starred {
                Image(systemName: "heart.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .padding(6)
                    .background(Theme.lcd.opacity(0.8), in: Circle())
                    .padding(Theme.s2)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if downloaded {
                LED(color: Theme.success, label: "En Mac")
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(Theme.lcd.opacity(0.8), in: Capsule())
                    .padding(Theme.s2)
                    .help("Ya está en tu carpeta de descargas")
            } else if isCurrentTransfer {
                ProgressView(value: currentFraction)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .padding(Theme.s2)
            }
        }
        .overlay {
            if hovering {
                Button { model.previewFile = file } label: {
                    Image(systemName: file.isVideo ? "play.fill" : "eye.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Theme.accent, in: Circle())
                        .shadow(color: Theme.accent.opacity(0.5), radius: 8)
                }
                .buttonStyle(.plain)
                .help(file.isVideo ? "Reproducir (espacio)" : "Ver (espacio)")
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .overlay(alignment: .topLeading) {
            // Visible on hover, and on every cell once something is selected, so it reads as a
            // checkbox: one click adds or removes this file, no modifier keys needed.
            if selected || hovering || !model.selection.isEmpty {
                Button { model.toggleInSelection(file) } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(selected ? Theme.accent : Theme.lcd.opacity(0.35))
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(.white.opacity(selected ? 0 : 0.9), lineWidth: 1.5)
                        if selected {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(.white)
                        }
                    }
                    .frame(width: 18, height: 18)
                    .shadow(color: .black.opacity(0.25), radius: 2)
                    .padding(Theme.s2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(selected ? "Quitar de la selección" : "Agregar a la selección")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous)
                .strokeBorder(selected ? Theme.accent : Theme.hairline, lineWidth: selected ? 3 : 1)
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
            Label(file.durationSec > 0 ? Format.duration(file.durationSec) : "VIDEO", systemImage: "play.fill")
                .labelStyle(BadgeLabelStyle())
        } else if file.isPanorama {
            Label("PANO", systemImage: "pano")
                .labelStyle(BadgeLabelStyle())
        } else if file.isBurst {
            Label("RÁFAGA", systemImage: "square.stack")
                .labelStyle(BadgeLabelStyle())
        }
    }

    private var meta: some View {
        HStack(spacing: Theme.s2) {
            Text(file.captureDate.map { Format.time.string(from: $0) } ?? file.name)
                .font(Theme.readout(12.5, weight: .bold))
                .foregroundStyle(Theme.ink)
            Text(details.uppercased())
                .font(Theme.label(9.5))
                .tracking(0.8)
                .foregroundStyle(Theme.muted)
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
        .font(Theme.readout(10, weight: .bold))
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Theme.lcd.opacity(0.8), in: Capsule())
    }
}
