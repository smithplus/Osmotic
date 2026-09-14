import OsmoticCore
import SwiftUI

/// The start screen: cameras in Bluetooth range, and the ones connected before.
struct CamerasView: View {
    @Environment(AppModel.self) private var model

    private var nearby: [DiscoveredCamera] { model.ble.sortedCameras }

    private var savedOutOfRange: [SavedCamera] {
        let near = Set(nearby.map(\.id))
        return model.savedCameras.filter { !near.contains($0.id) }
    }

    /// False only for debug snapshots — `ImageRenderer` cannot draw scroll-view content.
    var scrolls = true

    var body: some View {
        Group {
            if scrolls { ScrollView { content } } else { content }
        }
        .task {
            // Keep the list honest: drop cameras that stopped advertising.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                model.ble.pruneStale()
            }
        }
    }

    private var content: some View {
            VStack(alignment: .leading, spacing: Theme.s5) {
                header
                if let error = model.connectError {
                    ErrorBanner(message: error)
                }
                if model.restoringWifi {
                    Notice(symbol: "wifi", text: "Volviendo a tu red Wi-Fi…")
                }
                bluetoothNotice
                section(title: "Cerca", trailing: AnyView(ScanIndicator(active: model.ble.isScanning))) {
                    if nearby.isEmpty {
                        EmptyNearby()
                    } else {
                        ForEach(nearby) { cam in
                            CameraRow(title: cam.model.name, subtitle: cam.name, rssi: cam.rssi,
                                      saved: model.savedCameras.contains { $0.id == cam.id }, inRange: true) {
                                model.connect(cam)
                            }
                        }
                    }
                }
                if !savedOutOfRange.isEmpty {
                    section(title: "Conectadas antes", trailing: nil) {
                        ForEach(savedOutOfRange) { cam in
                            CameraRow(title: cam.modelName, subtitle: cam.bleName, rssi: nil, saved: true, inRange: false) {
                                model.connect(saved: cam)
                            }
                        }
                    }
                }
                DownloadFolderFooter()
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, Theme.s5)
            .padding(.vertical, Theme.s6)
            .frame(maxWidth: .infinity)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            Text("Osmotic")
                .font(Theme.display(34))
            Text("Bajá los videos y fotos de tu DJI Osmo directo al Mac, sin cables ni la app del teléfono.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var bluetoothNotice: some View {
        switch model.ble.power {
        case .poweredOff:
            Notice(symbol: "antenna.radiowaves.left.and.right.slash", text: "El Bluetooth está apagado. Encendelo para encontrar tu cámara.")
        case .unauthorized:
            Notice(symbol: "hand.raised", text: "Osmotic necesita permiso de Bluetooth: Ajustes del Sistema › Privacidad y seguridad › Bluetooth.")
        case .unsupported:
            Notice(symbol: "exclamationmark.triangle", text: "Este Mac no tiene Bluetooth LE.")
        default:
            EmptyView()
        }
    }

    private func section<Content: View>(title: String, trailing: AnyView?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                trailing
            }
            VStack(spacing: Theme.s2) { content() }
        }
    }
}

private struct CameraRow: View {
    let title: String
    let subtitle: String
    let rssi: Int?
    let saved: Bool
    let inRange: Bool
    let connect: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Theme.s3) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous)
                    .fill(inRange ? Theme.accent.opacity(0.14) : Color.secondary.opacity(0.1))
                Image(systemName: "camera.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(inRange ? Theme.accent : .secondary)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.s2) {
                    Text(title).font(.headline)
                    if saved {
                        Text("Guardada")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.14), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(inRange ? subtitle : "\(subtitle) · fuera de alcance")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let rssi {
                Image(systemName: "cellularbars", variableValue: Self.signal(rssi))
                    .foregroundStyle(.secondary)
                    .help("Señal \(rssi) dBm")
            }
            Button(inRange ? "Conectar" : "Intentar", action: connect)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(inRange ? Theme.accent : .gray)
        }
        .card(padding: Theme.s3)
        .scaleEffect(hovering ? 1.005 : 1)
        .animation(.snappy(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
    }

    static func signal(_ rssi: Int) -> Double {
        min(1, max(0.1, Double(rssi + 95) / 45))
    }
}

private struct EmptyNearby: View {
    var body: some View {
        HStack(alignment: .top, spacing: Theme.s3) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: Theme.s1) {
                Text("Encendé tu cámara y acercala al Mac")
                    .font(.headline)
                Text("Aparece acá en unos segundos. Funciona con Osmo Pocket 3, Pocket 4, Nano, Action 4, 5 Pro y 6.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: Theme.s4)
    }
}

private struct ScanIndicator: View {
    let active: Bool
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(active ? Theme.accent : Color.secondary)
                .frame(width: 7, height: 7)
                .opacity(active && pulse ? 0.25 : 1)
                .animation(active ? .easeInOut(duration: 0.9).repeatForever() : .default, value: pulse)
            Text(active ? "Buscando…" : "En pausa")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { pulse = true }
    }
}

struct Notice: View {
    let symbol: String
    let text: String
    var body: some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: symbol) }
            .font(.callout)
            .padding(Theme.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous))
    }
}

struct ErrorBanner: View {
    let message: String
    var body: some View {
        Label { Text(message).fixedSize(horizontal: false, vertical: true) } icon: {
            Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
        }
        .font(.callout)
        .padding(Theme.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.09), in: RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous))
    }
}

private struct DownloadFolderFooter: View {
    @Environment(AppModel.self) private var model
    @State private var folder = Preferences.downloadFolder

    var body: some View {
        HStack(spacing: Theme.s2) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            Text("Las descargas van a")
                .foregroundStyle(.secondary)
            Text(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Abrir") { model.openDownloadFolder() }
                .buttonStyle(.link)
            SettingsLink { Text("Cambiar…") }
                .buttonStyle(.link)
        }
        .font(.callout)
        .onAppear { folder = Preferences.downloadFolder }
    }
}
