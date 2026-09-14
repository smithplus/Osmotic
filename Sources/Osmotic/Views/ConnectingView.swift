import SwiftUI

/// The connection, one stage at a time — the screen that has to explain the parts the user takes part
/// in (approving on the camera, the Mac leaving its Wi-Fi) without drowning them in protocol.
struct ConnectingView: View {
    @Environment(AppModel.self) private var model
    @State private var password = ""

    /// False only for debug snapshots — `ImageRenderer` cannot draw scroll-view content.
    var scrolls = true

    var body: some View {
        if scrolls { ScrollView { content } } else { content }
    }

    private var content: some View {
            VStack(alignment: .leading, spacing: Theme.s4) {
                VStack(alignment: .leading, spacing: Theme.s2) {
                    LED(color: model.connectError == nil ? Theme.accent : Theme.danger,
                        state: model.connectError == nil ? .blink : .on,
                        label: model.connectError == nil ? "Conectando" : "Sin conexión")
                    Text((model.target?.model.name ?? "Cámara").uppercased())
                        .font(Theme.display(38))
                        .tracking(-1)
                        .foregroundStyle(Theme.ink)
                    if let t = model.target {
                        Text(t.name).font(Theme.readout(12)).foregroundStyle(Theme.muted)
                    }
                }

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(AppModel.Stage.allCases, id: \.self) { stage in
                        StageRow(stage: stage, state: state(of: stage),
                                 detail: stage == model.stage ? model.stageDetail : nil,
                                 progress: stage == .datalink && model.stage == .datalink && model.connectError == nil
                                    ? model.datalinkProgress : nil,
                                 isLast: stage == AppModel.Stage.allCases.last)
                    }
                }
                .card(padding: Theme.s4)

                if model.needsApproval && model.connectError == nil {
                    ApprovalCallout()
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                if let ssid = model.passwordPromptSSID, model.connectError == nil {
                    passwordCard(ssid)
                }

                if let error = model.connectError {
                    ErrorBanner(message: error)
                    HStack(spacing: Theme.s2) {
                        Button("Volver") { model.backToCameras() }
                            .buttonStyle(KeyButtonStyle(kind: .ghost))
                        Button("Reintentar") { model.retry() }
                            .buttonStyle(.signalKey)
                            .keyboardShortcut(.defaultAction)
                        Spacer()
                        OpenLogLink()
                    }
                } else {
                    HStack(alignment: .top, spacing: Theme.s3) {
                        Image(systemName: "wifi.exclamationmark")
                            .foregroundStyle(Theme.muted)
                        Text("Mientras dure la conexión, tu Mac usa el Wi-Fi de la cámara y queda sin Internet por Wi-Fi; al desconectar vuelve a tu red. Para seguir con Internet, conectá el Mac por Ethernet o el iPhone por cable con Compartir Internet.")
                            .font(.callout)
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: Theme.s4)
                        Button("Cancelar") { model.cancelConnect() }
                            .buttonStyle(KeyButtonStyle(kind: .ghost))
                            .keyboardShortcut(.cancelAction)
                    }
                }
            }
            .frame(maxWidth: 580, alignment: .leading)
            .padding(.horizontal, Theme.s5)
            .padding(.vertical, Theme.s6)
            .frame(maxWidth: .infinity)
            .animation(.smooth(duration: 0.3), value: model.stage)
            .animation(.smooth(duration: 0.3), value: model.needsApproval)
    }

    private func state(of stage: AppModel.Stage) -> StageRow.State {
        if stage < model.stage { return .done }
        if stage == model.stage { return model.connectError == nil ? .active : .failed }
        return .pending
    }

    private func passwordCard(_ ssid: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            Silk("Contraseña Wi-Fi de la cámara", color: Theme.ink)
            Text("La cámara no la envió por Bluetooth. Está en su pantalla: Ajustes › Conexión inalámbrica (red \(ssid)).")
                .font(.callout)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                SecureField("Contraseña", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.readout(13))
                    .onSubmit(submitPassword)
                Button("Continuar", action: submitPassword)
                    .buttonStyle(.signalKey)
                    .disabled(password.count < 8)
            }
        }
        .card()
    }

    private func submitPassword() {
        guard password.count >= 8 else { return }
        model.providePassword(password)
        password = ""
    }
}

private struct StageRow: View {
    enum State { case pending, active, done, failed }

    let stage: AppModel.Stage
    let state: State
    let detail: String?
    let progress: Double?
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Theme.s3) {
            Text(String(format: "%02d", stage.rawValue + 1))
                .font(Theme.readout(11, weight: .bold))
                .foregroundStyle(state == .pending ? Theme.muted : Theme.ink)
                .frame(width: 22, alignment: .leading)
                .padding(.top, 2)
            LED(color: ledColor, state: ledState)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 6) {
                Silk(stage.title, color: state == .pending ? Theme.muted : Theme.ink, size: 11.5)
                if let detail, !detail.isEmpty, state == .active || state == .failed {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(Theme.muted)
                        .contentTransition(.opacity)
                }
                if let progress {
                    SegmentMeter(value: progress, segments: 24, lit: Theme.accent, unlit: Theme.well)
                        .frame(maxWidth: 260)
                        .frame(height: 8)
                }
            }
            Spacer(minLength: 0)
            if state == .done { Silk("OK", color: Theme.success) }
        }
        .padding(.vertical, Theme.s2 + 2)
        .overlay(alignment: .bottom) {
            if !isLast { Rectangle().fill(Theme.hairline).frame(height: 1) }
        }
    }

    private var ledColor: Color {
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

/// The one step only the user can do: a signal-orange block.
private struct ApprovalCallout: View {
    @State private var nudge = false

    var body: some View {
        HStack(spacing: Theme.s3) {
            Image(systemName: "hand.tap.fill")
                .font(.system(size: 26))
                .foregroundStyle(.white)
                .offset(y: nudge ? -2 : 2)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: nudge)
            VStack(alignment: .leading, spacing: 4) {
                Silk("Acción requerida", color: .white.opacity(0.85))
                Text("Aprobá la conexión en la cámara")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                Text("En su pantalla aparece un pedido de emparejamiento: tocá el visto. Solo la primera vez.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.s4)
        .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.radiusL, style: .continuous))
        .shadow(color: Theme.accent.opacity(0.3), radius: 16, y: 6)
        .onAppear { nudge = true }
    }
}

struct OpenLogLink: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Registro técnico") { openWindow(id: "log") }
            .buttonStyle(.ghostKey)
    }
}
