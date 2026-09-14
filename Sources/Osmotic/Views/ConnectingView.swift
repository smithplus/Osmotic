import SwiftUI

/// The connection, one stage at a time — the screen that has to explain the parts the user takes part
/// in (approving on the camera, the Mac leaving its Wi-Fi) without drowning them in protocol.
struct ConnectingView: View {
    @Environment(AppModel.self) private var model
    @State private var password = ""
    @FocusState private var passwordFocused: Bool

    /// False only for debug snapshots — `ImageRenderer` cannot draw scroll-view content.
    var scrolls = true

    var body: some View {
        VStack(spacing: 0) {
            TopPlate {
                LED(
                    color: model.connectError == nil ? Theme.accent : Theme.danger,
                    state: model.connectError == nil ? .blink : .on,
                    label: model.connectError == nil ? "Connecting" : "Error")
            }
            Group {
                if scrolls { ScrollView { content } } else { content }
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Theme.s4) {
            // The display carries the one message that matters right now.
            LCDGlass {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        LCDText(
                            text: (model.target?.model.name ?? String(localized: "Camera")).uppercased(), size: 11,
                            weight: .medium,
                            color: Theme.lcdText.opacity(0.75))
                        Spacer()
                        LCDText(text: model.target?.name ?? "", size: 11, color: Theme.lcdText.opacity(0.75))
                    }
                    LCDText(text: lcdMessage, size: 16, weight: .medium)
                    if model.stage == .datalink && model.connectError == nil {
                        SegmentMeter(value: model.datalinkProgress, segments: 40).frame(height: 8)
                    }
                }
                .padding(.horizontal, Theme.s4)
                .padding(.vertical, Theme.s3 + 2)
            }

            // Five channels, left to right, like the status LEDs on a device.
            HStack(alignment: .top, spacing: 0) {
                ForEach(AppModel.Stage.allCases, id: \.self) { stage in
                    StageChannel(stage: stage, state: state(of: stage))
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, Theme.s3)
            .padding(.horizontal, Theme.s2)
            .raisedPanel(screws: true)

            if model.needsApproval && model.connectError == nil {
                ApprovalCallout()
                    .transition(.panelFromTop)
            }

            if let ssid = model.passwordPromptSSID, model.connectError == nil {
                passwordCard(ssid)
            }

            if let error = model.connectError {
                ErrorBanner(message: error)
                HStack(spacing: Theme.s2) {
                    CassetteKeyBank {
                        Button("Back") { model.backToCameras() }
                            .buttonStyle(.secondaryKey)
                        Button("Try Again") { model.retry() }
                            .buttonStyle(.primaryKey)
                            .keyboardShortcut(.defaultAction)
                    }
                    Spacer()
                    OpenLogLink()
                }
            } else {
                HStack(alignment: .top, spacing: Theme.s3) {
                    Text(
                        "While connected, your Mac uses the camera’s Wi-Fi and has no Internet over Wi-Fi; it goes back to your network when you disconnect. To stay online, plug the Mac into Ethernet or share an iPhone’s connection over USB."
                    )
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Theme.s4)
                    CassetteKeyBank {
                        Button("Cancel") { model.cancelConnect() }
                            .buttonStyle(.secondaryKey)
                            .keyboardShortcut(.cancelAction)
                    }
                }
            }
        }
        .frame(maxWidth: 580, alignment: .leading)
        .padding(.horizontal, Theme.s5)
        .padding(.top, Theme.s3)
        .padding(.bottom, Theme.s6)
        .frame(maxWidth: .infinity)
        .motion(Motion.panel, value: model.stage)
        .motion(Motion.panel, value: model.needsApproval)
        .motion(Motion.panel, value: model.connectError)
    }

    private var lcdMessage: String {
        if model.connectError != nil { return String(localized: "Not connected").uppercased() }
        if model.needsApproval { return String(localized: "Approve on the camera").uppercased() }
        return model.stageDetail.isEmpty ? model.stage.title.uppercased() : model.stageDetail.uppercased()
    }

    private func state(of stage: AppModel.Stage) -> StageChannel.State {
        if stage < model.stage { return .done }
        if stage == model.stage { return model.connectError == nil ? .active : .failed }
        return .pending
    }

    private func passwordCard(_ ssid: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.s2 + 2) {
            Silk("Camera Wi-Fi password", color: Theme.ink)
            Text(
                "The camera didn’t send it over Bluetooth. It’s on the camera’s screen: Settings › Wireless connection (network \(ssid))."
            )
            .font(.callout)
            .foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.s2) {
                SecureField("Camera Wi-Fi password", text: $password, prompt: Text("password (8 or more characters)"))
                    .labelsHidden()
                    .focused($passwordFocused)
                    .onAppear { passwordFocused = true }
                    .textFieldStyle(.plain)
                    .font(Theme.readout(13))
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .recessed(radius: 6)
                    .onSubmit(submitPassword)
                CassetteKeyBank {
                    Button("Continue", action: submitPassword)
                        .buttonStyle(.primaryKey)
                        .disabled(password.count < 8)
                }
            }
        }
        .padding(Theme.s3)
        .raisedPanel()
    }

    private func submitPassword() {
        guard password.count >= 8 else { return }
        model.providePassword(password)
        password = ""
    }
}

/// One status channel: a lens LED over its printed name.
private struct StageChannel: View {
    enum State { case pending, active, done, failed }
    let stage: AppModel.Stage
    let state: State

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                LED(color: color, state: ledState, size: 11)
                // A shape as well as a colour: a tick when done, a cross when it failed.
                if state == .done || state == .failed {
                    Image(systemName: state == .done ? "checkmark" : "xmark")
                        .font(.system(size: 6.5, weight: .heavy))
                        .foregroundStyle(.black.opacity(0.7))
                }
            }
            Silk(shortTitle, color: state == .pending ? Theme.muted : Theme.ink, size: 9)
                .multilineTextAlignment(.center)
            Text(String(format: "%02ld", stage.rawValue + 1))
                .font(Theme.readout(9, weight: .bold))
                .foregroundStyle(Theme.muted)
        }
        // One element per stage: "Pair, step 2 of 5, in progress" — not just a colour.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(shortTitle))
        .accessibilityValue(Text(spokenState))
        .accessibilityHint(Text("Step \(stage.rawValue + 1) of \(AppModel.Stage.allCases.count)"))
    }

    private var spokenState: LocalizedStringKey {
        switch state {
        case .pending: "Waiting"
        case .active: "In progress"
        case .done: "Done"
        case .failed: "Failed"
        }
    }

    private var shortTitle: LocalizedStringKey {
        switch stage {
        case .bluetooth: "Bluetooth"
        case .pairing: "Pair"
        case .wifi: "Wi-Fi"
        case .datalink: "Link"
        case .library: "Library"
        }
    }

    private var color: Color {
        switch state {
        case .failed: Theme.danger
        case .done: Theme.success
        default: Theme.accent
        }
    }

    private var ledState: LED.State {
        switch state {
        case .pending: .off
        case .active: .blink
        case .done, .failed: .on
        }
    }
}

/// The one step only the user can do.
private struct ApprovalCallout: View {
    var body: some View {
        HStack(spacing: Theme.s3) {
            Image(systemName: "hand.tap.fill")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(LinearGradient(colors: [Theme.accentTop, Theme.accentBottom], startPoint: .top, endPoint: .bottom))
                }
                .shadow(Depth.contact)
            VStack(alignment: .leading, spacing: 3) {
                Text("Approve the connection on the camera")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.ink)
                Text("A pairing request shows up on its screen: tap the check mark. Only needed the first time.")
                    .font(.callout)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.s3)
        .raisedPanel()
    }
}

struct OpenLogLink: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        CassetteKeyBank(compact: true) {
            Button("Technical log") { openWindow(id: "log") }
                .buttonStyle(.compactKey)
        }
    }
}
