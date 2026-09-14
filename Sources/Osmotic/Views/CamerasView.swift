import OsmoticCore
import SwiftUI

/// The start screen: the display says what the radio is doing; below it, one module per camera.
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
        VStack(spacing: 0) {
            TopPlate {
                LED(color: model.ble.power == .poweredOn ? Theme.success : Theme.danger,
                    state: model.ble.power == .poweredOn ? .on : .blink, label: "Bluetooth")
            }
            Group {
                if scrolls { ScrollView { content } } else { content }
            }
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
        VStack(alignment: .leading, spacing: Theme.s4) {
            display
            if let error = model.connectError { ErrorBanner(message: error) }
            if model.restoringWifi { Notice(text: "Volviendo a tu red Wi-Fi…") }
            bluetoothNotice

            VStack(alignment: .leading, spacing: Theme.s2 + 2) {
                SectionIndex(number: 1, title: "Cerca")
                if nearby.isEmpty {
                    EmptyNearby()
                } else {
                    ForEach(nearby) { cam in
                        CameraModule(title: cam.model.name, subtitle: cam.name, rssi: cam.rssi,
                                     saved: model.savedCameras.contains { $0.id == cam.id }, inRange: true) {
                            model.connect(cam)
                        }
                    }
                }
            }

            if !savedOutOfRange.isEmpty {
                VStack(alignment: .leading, spacing: Theme.s2 + 2) {
                    SectionIndex(number: 2, title: "Conectadas antes")
                    ForEach(savedOutOfRange) { cam in
                        CameraModule(title: cam.modelName, subtitle: cam.bleName, rssi: nil, saved: true, inRange: false) {
                            model.connect(saved: cam)
                        }
                    }
                }
            }

            DownloadFolderFooter()
        }
        .frame(maxWidth: 620, alignment: .leading)
        .padding(.horizontal, Theme.s5)
        .padding(.top, Theme.s3)
        .padding(.bottom, Theme.s6)
        .frame(maxWidth: .infinity)
    }

    /// The LCD: what the radio is doing, in the device's own words.
    private var display: some View {
        LCDGlass {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 6) {
                    LCDText(text: nearby.isEmpty ? (model.ble.isScanning ? "BUSCANDO CÁMARAS…" : "EN PAUSA")
                                                 : String(format: "%02d CÁMARA%@ CERCA", nearby.count, nearby.count == 1 ? "" : "S"),
                            size: 17, weight: .bold)
                    LCDText(text: "OSMO › MAC  ·  SIN CABLES  ·  SIN APP", size: 10.5, weight: .medium,
                            color: Theme.lcdText.opacity(0.55))
                }
                Spacer()
                ScanBars(active: model.ble.isScanning)
            }
            .padding(.horizontal, Theme.s4)
            .padding(.vertical, Theme.s3 + 2)
        }
    }

    @ViewBuilder private var bluetoothNotice: some View {
        switch model.ble.power {
        case .poweredOff: Notice(text: "El Bluetooth está apagado. Encendelo para encontrar tu cámara.")
        case .unauthorized: Notice(text: "Osmotic necesita permiso de Bluetooth: Ajustes del Sistema › Privacidad y seguridad › Bluetooth.")
        case .unsupported: Notice(text: "Este Mac no tiene Bluetooth LE.")
        default: EmptyView()
        }
    }
}

/// A radio "activity" graphic for the LCD: bars that breathe while scanning.
private struct ScanBars: View {
    let active: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12, paused: !active)) { t in
            let phase = t.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<9, id: \.self) { i in
                    let h = active ? 6 + 18 * abs(sin(phase * 2.2 + Double(i) * 0.7)) : 4
                    Rectangle()
                        .fill(Theme.lcdText.opacity(active ? 0.9 : 0.25))
                        .frame(width: 3, height: h)
                        .shadow(color: Theme.lcdText.opacity(0.5), radius: 2)
                }
            }
            .frame(height: 26, alignment: .bottom)
        }
    }
}

/// One camera: a raised module with an engraved glyph pocket, its name plate, signal LEDs and a key.
private struct CameraModule: View {
    let title: String
    let subtitle: String
    let rssi: Int?
    let saved: Bool
    let inRange: Bool
    let connect: () -> Void

    var body: some View {
        HStack(spacing: Theme.s3) {
            Image(systemName: "camera.fill")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.ink.opacity(inRange ? 0.75 : 0.35))
                .frame(width: 46, height: 46)
                .recessed(radius: Theme.radiusM)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.ink)
                HStack(spacing: 6) {
                    Text(subtitle).font(Theme.readout(11)).foregroundStyle(Theme.muted)
                    if saved { Silk("· guardada") }
                    if !inRange { Silk("· fuera de alcance") }
                }
            }
            Spacer()
            if let rssi {
                SignalLEDs(level: Self.level(rssi)).help("Señal \(rssi) dBm")
            }
            Button(inRange ? "Conectar" : "Intentar", action: connect)
                .buttonStyle(KeyButtonStyle(kind: inRange ? .signal : .ghost))
        }
        .padding(Theme.s3 - 2)
        .raisedPanel()
    }

    static func level(_ rssi: Int) -> Int { min(4, max(1, (rssi + 100) / 11)) }
}

/// Four small green LEDs for signal strength.
private struct SignalLEDs: View {
    let level: Int
    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 3) {
                ForEach(0..<4, id: \.self) { i in LED(color: Theme.success, state: i < level ? .on : .off, size: 6) }
            }
            Silk("señal", size: 8)
        }
    }
}

private struct EmptyNearby: View {
    var body: some View {
        HStack(spacing: Theme.s3) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.ink.opacity(0.45))
                .frame(width: 46, height: 46)
                .recessed()
            VStack(alignment: .leading, spacing: 3) {
                Text("Encendé tu cámara y acercala al Mac")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.ink)
                Text("Pocket 3 · Pocket 4 · Nano · Action 4 · 5 Pro · 6")
                    .font(Theme.readout(11))
                    .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.s3 - 2)
        .raisedPanel()
    }
}

/// A printed notice with an amber LED.
struct Notice: View {
    let text: String
    var body: some View {
        HStack(spacing: Theme.s2 + 2) {
            LED(color: Theme.warning, state: .on)
            Text(text).font(.callout).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Theme.s3 - 4)
        .recessed()
    }
}

struct ErrorBanner: View {
    let message: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.s2 + 2) {
            LED(color: Theme.danger, state: .on)
            Text(message).font(.callout).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Theme.s3 - 4)
        .recessed()
    }
}

private struct DownloadFolderFooter: View {
    @Environment(AppModel.self) private var model
    @State private var folder = Preferences.downloadFolder

    var body: some View {
        HStack(spacing: Theme.s2 + 2) {
            Silk("Destino", color: Theme.ink)
            Text(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(Theme.readout(11.5, weight: .medium))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .recessed(radius: 6)
            Button("Abrir") { model.openDownloadFolder() }
                .buttonStyle(.ghostKey)
            SettingsLink { Text("Cambiar") }
                .buttonStyle(.ghostKey)
        }
        .padding(.top, Theme.s2)
        .onAppear { folder = Preferences.downloadFolder }
    }
}
