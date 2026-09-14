import OsmoticCore
import SwiftUI

/// The start screen: cameras in Bluetooth range, and the ones connected before.
struct CamerasView: View {
    @Environment(AppModel.self) private var model
    /// False only for debug snapshots — `ImageRenderer` cannot draw scroll-view content.
    var scrolls = true

    private var nearby: [DiscoveredCamera] { model.ble.sortedCameras }

    private var savedOutOfRange: [SavedCamera] {
        let near = Set(nearby.map(\.id))
        return model.savedCameras.filter { !near.contains($0.id) }
    }

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
            if let error = model.connectError { ErrorBanner(message: error) }
            if model.restoringWifi { Notice(symbol: "wifi", text: "Volviendo a tu red Wi-Fi…") }
            bluetoothNotice

            VStack(alignment: .leading, spacing: Theme.s3) {
                SectionIndex(number: 1, title: "Cerca", trailing: AnyView(
                    LED(color: Theme.accent, state: model.ble.isScanning ? .blink : .off,
                        label: model.ble.isScanning ? "Buscando" : "En pausa")))
                if nearby.isEmpty {
                    EmptyNearby()
                } else {
                    ForEach(Array(nearby.enumerated()), id: \.element.id) { i, cam in
                        CameraModule(slot: i + 1, title: cam.model.name, subtitle: cam.name, rssi: cam.rssi,
                                     saved: model.savedCameras.contains { $0.id == cam.id }, inRange: true) {
                            model.connect(cam)
                        }
                    }
                }
            }

            if !savedOutOfRange.isEmpty {
                VStack(alignment: .leading, spacing: Theme.s3) {
                    SectionIndex(number: 2, title: "Conectadas antes")
                    ForEach(Array(savedOutOfRange.enumerated()), id: \.element.id) { i, cam in
                        CameraModule(slot: nearby.count + i + 1, title: cam.modelName, subtitle: cam.bleName,
                                     rssi: nil, saved: true, inRange: false) {
                            model.connect(saved: cam)
                        }
                    }
                }
            }

            DownloadFolderFooter()
        }
        .frame(maxWidth: 680, alignment: .leading)
        .padding(.horizontal, Theme.s5)
        .padding(.vertical, Theme.s6)
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            HStack(alignment: .firstTextBaseline) {
                Text("OSMOTIC")
                    .font(Theme.display(46))
                    .tracking(-1.5)
                    .foregroundStyle(Theme.ink)
                Circle().fill(Theme.accent).frame(width: 12, height: 12)
                    .shadow(color: Theme.accent.opacity(0.8), radius: 8)
                    .offset(y: -4)
                Spacer()
                Silk("v0.1 · MAC", size: 10)
            }
            HStack(spacing: Theme.s3) {
                Silk("DJI Osmo", color: Theme.ink)
                Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.accent)
                Silk("Mac", color: Theme.ink)
                Rectangle().fill(Theme.hairline).frame(width: 24, height: 1)
                Silk("Sin cables · sin app · sin cuenta")
            }
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
}

/// One camera as a hardware module: slot number, glyph well, name plate, signal dots, key.
private struct CameraModule: View {
    let slot: Int
    let title: String
    let subtitle: String
    let rssi: Int?
    let saved: Bool
    let inRange: Bool
    let connect: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Theme.s3) {
            Text(String(format: "%02d", slot))
                .font(Theme.readout(11, weight: .bold))
                .foregroundStyle(Theme.muted)
                .frame(width: 22)

            ZStack {
                RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous).fill(inRange ? Theme.ink : Theme.well)
                Image(systemName: "camera.fill")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(inRange ? Theme.accent : Theme.muted)
            }
            .frame(width: 50, height: 50)

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Theme.ink)
                HStack(spacing: Theme.s2) {
                    Text(subtitle)
                        .font(Theme.readout(11.5))
                        .foregroundStyle(Theme.muted)
                    if saved { Silk("· Guardada", size: 9.5) }
                    if !inRange { Silk("· Fuera de alcance", size: 9.5) }
                }
            }
            Spacer()
            if let rssi { SignalDots(level: Self.level(rssi)).help("Señal \(rssi) dBm") }
            Button(inRange ? "Conectar" : "Intentar", action: connect)
                .buttonStyle(KeyButtonStyle(kind: inRange ? .signal : .ghost, compact: !inRange))
        }
        .card(padding: Theme.s3)
        .offset(y: hovering ? -2 : 0)
        .animation(.snappy(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
    }

    static func level(_ rssi: Int) -> Int { min(5, max(1, (rssi + 100) / 9)) }
}

/// Five-dot signal meter.
private struct SignalDots: View {
    let level: Int
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { i in
                Circle()
                    .fill(i < level ? Theme.ink : Theme.well)
                    .frame(width: 5, height: 5)
            }
        }
    }
}

private struct EmptyNearby: View {
    var body: some View {
        HStack(alignment: .center, spacing: Theme.s4) {
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .strokeBorder(Theme.accent.opacity(0.9 - Double(i) * 0.3), style: StrokeStyle(lineWidth: 1.2, dash: [2, 3]))
                        .frame(width: 26 + CGFloat(i) * 16, height: 26 + CGFloat(i) * 16)
                }
                Circle().fill(Theme.accent).frame(width: 8, height: 8)
                    .shadow(color: Theme.accent.opacity(0.8), radius: 6)
            }
            .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: Theme.s1) {
                Text("Encendé tu cámara y acercala al Mac")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.ink)
                Text("Aparece acá en unos segundos. Pocket 3 · Pocket 4 · Nano · Action 4 · 5 Pro · 6")
                    .font(Theme.readout(11.5))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .card(padding: Theme.s4)
    }
}

struct Notice: View {
    let symbol: String
    let text: String
    var body: some View {
        HStack(spacing: Theme.s3) {
            LED(color: Theme.warning)
            Text(text).font(.callout).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Theme.s3)
        .background(Theme.warning.opacity(0.14), in: RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous))
    }
}

struct ErrorBanner: View {
    let message: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.s3) {
            LED(color: Theme.danger)
            VStack(alignment: .leading, spacing: 4) {
                Silk("Error", color: Theme.danger)
                Text(message).font(.callout).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.s3)
        .background(Theme.danger.opacity(0.09), in: RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous))
    }
}

private struct DownloadFolderFooter: View {
    @Environment(AppModel.self) private var model
    @State private var folder = Preferences.downloadFolder

    var body: some View {
        HStack(spacing: Theme.s3) {
            Silk("Destino")
            Text(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(Theme.readout(12, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Abrir") { model.openDownloadFolder() }
                .buttonStyle(.ghostKey)
            SettingsLink { Text("Cambiar") }
                .buttonStyle(.ghostKey)
        }
        .padding(.top, Theme.s2)
        .onAppear { folder = Preferences.downloadFolder }
    }
}
