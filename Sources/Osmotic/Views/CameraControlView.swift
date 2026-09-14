import OsmoticCore
import SwiftUI

/// The camera side of the library screen: a monitor with the live picture, the capture readout, the
/// mode keys and the shutter.
struct CameraControlView: View {
    @Environment(AppModel.self) private var model
    /// Debug snapshots can't draw the AppKit video layer: they show this still instead.
    var snapshotStill: NSImage? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            CaptureDisplay()
            monitor
            HStack(alignment: .bottom, spacing: Theme.s4) {
                modeKeys
                Spacer(minLength: 0)
                shutter
            }
            if let error = model.controlError {
                ErrorBanner(message: error).transition(.panelFromTop)
            }
        }
        .motion(Motion.panel, value: model.controlError)
    }

    private var monitor: some View {
        ZStack {
            if let snapshotStill {
                Image(nsImage: snapshotStill).resizable().scaledToFill()
            } else {
                LiveVideoView(renderer: model.liveRenderer)
            }
            if model.liveView != .live && snapshotStill == nil {
                LCDText(text: liveCaption.uppercased(), size: 12, weight: .medium,
                        color: model.liveView == .unavailable ? Theme.warning : Theme.lcdText.opacity(0.75))
            }
        }
        // The picture's own shape: landscape, or portrait when the camera films vertically.
        .aspectRatio(snapshotStill.map { $0.size.width / max(1, $0.size.height) } ?? model.liveAspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous))
        .modifier(Pocket(fill: .black, radius: Theme.radiusM, deep: true))
        .overlay(alignment: .topLeading) {
            if model.status.recording {
                HStack(spacing: 7) {
                    LED(color: Theme.danger, state: .blink, spokenState: "Recording")
                    LCDText(text: "REC " + Format.clock(TimeInterval(model.status.recordingSeconds)), size: 12, weight: .medium,
                            color: .white)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(Theme.s3)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live view")
        .accessibilityValue(Text(liveCaption))
    }

    private var liveCaption: String {
        switch model.liveView {
        case .off: String(localized: "Live view off")
        case .starting: String(localized: "Starting live view…")
        case .live: String(localized: "Live")
        case .unavailable: String(localized: "No live view from this camera")
        }
    }

    private var modeKeys: some View {
        VStack(alignment: .leading, spacing: 6) {
            BankLegend(text: "Mode")
            CassetteKeyBank {
                ForEach(CaptureMode.deck) { m in
                    Button(m.title) { model.setMode(m) }
                        .buttonStyle(CassetteKeyStyle(latched: model.status.captureMode == m, width: 66))
                        .accessibilityAddTraits(model.status.captureMode == m ? .isSelected : [])
                        .disabled(model.controlBusy || model.status.recording)
                }
            }
        }
        .fixedSize()
    }

    private var shutter: some View {
        VStack(alignment: .leading, spacing: 6) {
            BankLegend(text: "Shutter")
            CassetteKeyBank {
                let recording = model.status.recording
                let records = model.status.captureMode?.records ?? true
                Button { model.pressShutter() } label: {
                    if recording {
                        Label("Stop", systemImage: "stop.fill")
                    } else if records {
                        Label("Record", systemImage: "record.circle")
                    } else {
                        Label("Take photo", systemImage: "camera.fill")
                    }
                }
                .buttonStyle(CassetteKeyStyle(finish: .primary, width: 132))
                .disabled(model.controlBusy)
                .keyboardShortcut(.return, modifiers: [])
                .help(recording ? "Stop recording (↩)" : records ? "Start recording (↩)" : "Take a photo (↩)")
            }
        }
        .fixedSize()
    }
}

/// The capture readout: mode, recording time, battery, space left.
private struct CaptureDisplay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.status
        LCDGlass {
            HStack(spacing: Theme.s4) {
                LCDText(text: (model.target?.model.name ?? String(localized: "Camera")).uppercased(), size: 12.5, weight: .medium)
                LCDPair(label: "Mode", value: (s.captureMode?.shortTitle ?? "--").uppercased())
                LCDPair(label: "Rec", value: s.recording ? Format.clock(TimeInterval(s.recordingSeconds)) : "--:--",
                        color: s.recording ? Theme.danger : Theme.lcdText)
                Spacer(minLength: Theme.s2)
                LCDPair(label: "Batt", value: s.batteryPercent >= 0 ? "\(s.batteryPercent)%" : "--",
                        color: (0...15).contains(s.batteryPercent) ? Theme.danger : Theme.lcdText)
                if let st = s.displayStorage {
                    LCDPair(label: "Free", value: Format.compact(bytes: st.freeMb * 1_048_576))
                }
            }
            .padding(.horizontal, Theme.s3 + 2)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension CaptureMode {
    var title: LocalizedStringKey {
        switch self {
        case .video: "Video"
        case .photo: "Photo"
        case .slowMotion: "Slow-mo"
        case .timelapse: "Timelapse"
        case .hyperlapse: "Hyperlapse"
        case .lowLight: "Low light"
        case .panorama: "Pano"
        case .motionlapse: "Motionlapse"
        }
    }

    var shortTitle: String {
        switch self {
        case .video: String(localized: "Video")
        case .photo: String(localized: "Photo")
        case .slowMotion: String(localized: "Slow-mo")
        case .timelapse: String(localized: "Timelapse")
        case .hyperlapse: String(localized: "Hyperlapse")
        case .lowLight: String(localized: "Low light")
        case .panorama: String(localized: "Pano")
        case .motionlapse: String(localized: "Motionlapse")
        }
    }
}
