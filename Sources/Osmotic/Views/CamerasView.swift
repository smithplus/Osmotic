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
                WorkspaceTabs()
            } trailing: {
                HStack(spacing: Theme.s3) {
                    switch model.ble.power {
                    case .poweredOn: LED(color: Theme.success, state: .on, label: "Bluetooth")
                    case .unknown: LED(state: .off, label: "Bluetooth", spokenState: "Starting")
                    default: LED(color: Theme.danger, state: .blink, label: "Bluetooth", spokenState: "Unavailable")
                    }
                    CassetteKeyBank(compact: true) { SettingsKey() }
                }
            }
            if model.workspace == .webcam {
                WebcamView()
            } else {
                Group {
                    if scrolls { ScrollView { content } } else { content }
                }
            }
        }
        // Scanning costs radio and CPU: only while someone can see the list.
        .onChange(of: AppVisibility.shared.visible) { _, visible in
            guard model.screen == .cameras else { return }
            if visible { model.ble.startScan() } else { model.ble.stopScan() }
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
            if model.restoringWifi { Notice(text: "Going back to your Wi-Fi…").transition(.panelFromTop) }
            if model.wifiRestoreFailed && !model.restoringWifi {
                Notice(text: "Couldn’t get back to your Wi-Fi on its own. Pick your network in the menu bar.")
                    .transition(.panelFromTop)
            }
            // The automatic disconnect after downloads lands here: say how it went.
            if let summary = model.lastTransferSummary, !model.restoringWifi {
                Notice(verbatim: summary.text, color: summary.ok ? Theme.success : Theme.warning)
            }
            bluetoothNotice
            if case .available(let release) = model.updater.state {
                HStack(spacing: Theme.s3) {
                    Notice(text: "Osmotic \(release.version.description) is available.", color: Theme.success)
                    CassetteKeyBank {
                        Button(model.updater.canInstall ? "Install" : "Details") {
                            Task { await model.updater.install(release) }
                        }
                        .buttonStyle(.secondaryKey)
                    }
                }
                .transition(.panelFromTop)
            }

            if !model.cards.cards.isEmpty || model.cards.accessDenied {
                VStack(alignment: .leading, spacing: Theme.s2 + 2) {
                    SectionIndex(number: 1, title: "Plugged in")
                    ForEach(model.cards.cards) { card in
                        CardModule(card: card, busy: model.transfer != nil) { model.openCard(card) }
                    }
                    if model.cards.accessDenied {
                        // macOS keeps files on removable volumes behind a permission; the reader can
                        // grant it in System Settings, or point at the card here and skip the question.
                        HStack(spacing: Theme.s3) {
                            Notice(
                                text:
                                    "macOS won’t let Osmotic read the card yet. Allow it in System Settings › Privacy & Security › Files and Folders, or pick the card yourself.",
                                color: Theme.warning)
                            CassetteKeyBank {
                                Button("Choose Card…") { model.chooseCard() }
                                    .buttonStyle(.secondaryKey)
                            }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: Theme.s2 + 2) {
                SectionIndex(number: model.cards.cards.isEmpty ? 1 : 2, title: "Nearby")
                if nearby.isEmpty {
                    if bluetoothReady { EmptyNearby() }
                } else {
                    ForEach(nearby) { cam in
                        // One orange key per screen: the first camera's. The rest are plain Connect keys.
                        CameraModule(
                            title: cam.model.name, subtitle: cam.name, rssi: cam.rssi,
                            saved: model.savedCameras.contains { $0.id == cam.id }, inRange: true,
                            primary: cam.id == nearby.first?.id, enabled: bluetoothReady
                        ) {
                            model.connect(cam)
                        }
                    }
                }
            }

            if !savedOutOfRange.isEmpty {
                VStack(alignment: .leading, spacing: Theme.s2 + 2) {
                    SectionIndex(number: model.cards.cards.isEmpty ? 2 : 3, title: "Connected before")
                    ForEach(savedOutOfRange) { cam in
                        CameraModule(
                            title: cam.modelName, subtitle: cam.bleName, rssi: nil, saved: true, inRange: false,
                            enabled: bluetoothReady
                        ) {
                            model.connect(saved: cam)
                        }
                    }
                }
            }

            DownloadFolderFooter()
        }
        .frame(maxWidth: 620, alignment: .leading)
        // The notices above slide in on rails (their `.panelFromTop` needs an animated change).
        .motion(Motion.panel, value: model.restoringWifi)
        .motion(Motion.panel, value: model.wifiRestoreFailed)
        .motion(Motion.panel, value: updateAvailable)
        .padding(.horizontal, Theme.s5)
        .padding(.top, Theme.s3)
        .padding(.bottom, Theme.s6)
        .frame(maxWidth: .infinity)
    }

    private var updateAvailable: Bool {
        if case .available = model.updater.state { return true }
        return false
    }

    /// The LCD: what the radio is doing, in the device's own words.
    private var display: some View {
        LCDGlass {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 6) {
                    LCDText(text: headline, size: 16, weight: .medium)
                    LCDText(
                        text: String(localized: "Osmo › Mac  ·  Wireless  ·  No phone").uppercased(), size: 10.5,
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
        let text: String =
            switch model.ble.power {
            case .poweredOff: String(localized: "Bluetooth off")
            case .unauthorized: String(localized: "No Bluetooth access")
            case .unsupported: String(localized: "No Bluetooth LE")
            default:
                nearby.isEmpty
                    ? (model.ble.isScanning ? String(localized: "Searching…") : String(localized: "Paused"))
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
                    .buttonStyle(.secondaryKey)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        // 4 refreshes a second and heights snapped to 3 pt segments: an LCD bar graph, not a
        // smooth animation.
        TimelineView(.animation(minimumInterval: 0.25, paused: !active || reduceMotion || !AppVisibility.shared.visible)) { t in
            let phase = t.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<9, id: \.self) { i in
                    let h = active ? ((6 + 18 * abs(sin(phase * 2.2 + Double(i) * 0.7))) / 3).rounded() * 3 : 4
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
    var primary = false
    var enabled = true
    let connect: () -> Void

    var body: some View {
        HStack(spacing: Theme.s3) {
            Image(systemName: "camera.fill")
                .accessibilityHidden(true)
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
                    .buttonStyle(CassetteKeyStyle(finish: inRange && primary ? .primary : .secondary))
                    .disabled(!enabled)
                    .accessibilityLabel(Text("Connect to \(subtitle)"))
            }
        }
        .padding(.vertical, Theme.s3 - 2)
        .padding(.horizontal, Theme.s3)
        .raisedPanel(screws: true)
    }

    static func level(_ rssi: Int) -> Int { BluetoothService.signalLevel(rssi) }
}

/// A card plugged in over USB: what it is, how full it is, and how fast the cable negotiated.
private struct CardModule: View {
    let card: CardWatcher.Card
    let busy: Bool
    let open: () -> Void

    var body: some View {
        HStack(spacing: Theme.s3) {
            Image(systemName: "sdcard.fill")
                .accessibilityHidden(true)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.ink.opacity(0.75))
                .frame(width: 46, height: 46)
                .recessed(radius: Theme.radiusM)

            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: card.name)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.ink)
                HStack(spacing: 6) {
                    if let link = card.link {
                        Silk(verbatim: link.label + " · " + link.headline)
                    }
                    if card.totalBytes > 0 {
                        Silk(verbatim: "· " + Format.compact(bytes: card.freeBytes) + " free")
                    }
                }
            }
            Spacer()
            CassetteKeyBank {
                Button("Open", action: open)
                    .buttonStyle(CassetteKeyStyle(finish: .primary))
                    .disabled(busy)
                    .accessibilityLabel(Text("Open the card \(card.name)"))
            }
        }
        .padding(.vertical, Theme.s3 - 2)
        .padding(.horizontal, Theme.s3)
        .raisedPanel(screws: true)
        .help(Text("The camera's card, over the cable. No Wi-Fi, and your Internet stays on."))
    }
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
                .accessibilityHidden(true)
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
