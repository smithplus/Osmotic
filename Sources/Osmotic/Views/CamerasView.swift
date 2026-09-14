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
                switch model.ble.power {
                case .poweredOn: LED(color: Theme.success, state: .on, label: "Bluetooth")
                case .unknown: LED(state: .off, label: "Bluetooth", spokenState: "Starting")
                default: LED(color: Theme.danger, state: .blink, label: "Bluetooth", spokenState: "Unavailable")
                }
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
            if model.restoringWifi { Notice(text: "Going back to your Wi-Fi…") }
            // The automatic disconnect after downloads lands here: say how it went.
            if let summary = model.lastTransferSummary, !model.restoringWifi {
                Notice(verbatim: summary.text, color: summary.ok ? Theme.success : Theme.warning)
            }
            bluetoothNotice

            VStack(alignment: .leading, spacing: Theme.s2 + 2) {
                SectionIndex(number: 1, title: "Nearby")
                if nearby.isEmpty {
                    if bluetoothReady { EmptyNearby() }
                } else {
                    ForEach(nearby) { cam in
                        CameraModule(title: cam.model.name, subtitle: cam.name, rssi: cam.rssi,
                                     saved: model.savedCameras.contains { $0.id == cam.id }, inRange: true,
                                     enabled: bluetoothReady) {
                            model.connect(cam)
                        }
                    }
                }
            }

            if !savedOutOfRange.isEmpty {
                VStack(alignment: .leading, spacing: Theme.s2 + 2) {
                    SectionIndex(number: 2, title: "Connected before")
                    ForEach(savedOutOfRange) { cam in
                        CameraModule(title: cam.modelName, subtitle: cam.bleName, rssi: nil, saved: true, inRange: false,
                                     enabled: bluetoothReady) {
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
                    LCDText(text: headline, size: 16, weight: .medium)
                    LCDText(text: String(localized: "Osmo › Mac  ·  No cables  ·  No app").uppercased(), size: 10.5,
                            weight: .medium, color: Theme.lcdText.opacity(0.75))
                }
                Spacer()
                ScanBars(active: model.ble.isScanning)
            }
            .padding(.horizontal, Theme.s4)
            .padding(.vertical, Theme.s3 + 2)
        }
    }

    private var bluetoothReady: Bool { model.ble.power == .poweredOn || model.ble.power == .unknown }

    private var headline: String {
        let text: String = switch model.ble.power {
        case .poweredOff: String(localized: "Bluetooth off")
        case .unauthorized: String(localized: "No Bluetooth access")
        case .unsupported: String(localized: "No Bluetooth LE")
        default:
            nearby.isEmpty ? (model.ble.isScanning ? String(localized: "Searching…") : String(localized: "Paused"))
                           : String(localized: "\(nearby.count) cameras found")
        }
        return text.uppercased()
    }

    @ViewBuilder private var bluetoothNotice: some View {
        switch model.ble.power {
        case .poweredOff: Notice(text: "Bluetooth is off. Turn it on to find your camera.")
        case .unauthorized:
            HStack(spacing: Theme.s3) {
                Notice(text: "Osmotic needs Bluetooth permission: System Settings › Privacy & Security › Bluetooth.")
                CassetteKeyBank {
                    Button("Open Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.primaryKey)
                }
            }
        case .unsupported: Notice(text: "This Mac doesn’t have Bluetooth LE.")
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
                        .shadow(Depth.glow(Theme.lcdText))
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
    var enabled = true
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
                    if saved { Silk("· saved") }
                    if !inRange { Silk("· out of range") }
                }
            }
            Spacer()
            if let rssi {
                SignalLEDs(level: Self.level(rssi)).help("Signal \(rssi) dBm")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Signal")
                    .accessibilityValue(Text("\(Self.level(rssi)) of 4"))
            }
            CassetteKeyBank {
                Button("Connect", action: connect)
                    .buttonStyle(CassetteKeyStyle(finish: inRange ? .primary : .secondary))
                    .disabled(!enabled)
            }
        }
        .padding(.vertical, Theme.s3 - 2)
        .padding(.horizontal, Theme.s3)
        .raisedPanel(screws: true)
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
            Silk("signal", size: 8)
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
                Text("Turn on your camera and bring it close to the Mac")
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
    let text: Text
    var color: Color = Theme.warning

    init(text: LocalizedStringKey, color: Color = Theme.warning) {
        self.text = Text(text)
        self.color = color
    }

    init(verbatim: String, color: Color = Theme.warning) {
        self.text = Text(verbatim: verbatim)
        self.color = color
    }

    var body: some View {
        HStack(spacing: Theme.s2 + 2) {
            LED(color: color, state: .on).accessibilityHidden(true)
            text.font(.callout).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
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
            LED(color: Theme.danger, state: .on).accessibilityHidden(true)
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
            Silk("Saving to", color: Theme.ink)
            Text(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(Theme.readout(11.5, weight: .medium))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .recessed(radius: 6)
            CassetteKeyBank(compact: true) {
                Button("Show in Finder") { model.openDownloadFolder() }
                    .buttonStyle(.compactKey)
                SettingsLink { Text("Change…") }
                    .buttonStyle(.compactKey)
            }
        }
        .padding(.top, Theme.s2)
        .onAppear { folder = Preferences.downloadFolder }
        // "Change…" happens in the Settings window: follow it.
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            let now = Preferences.downloadFolder
            if now != folder { folder = now }
        }
    }
}
