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
                VStack(alignment: .leading, spacing: Theme.s1) {
                    Text(model.connectError == nil ? "Conectando" : "No se pudo conectar")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text(model.target?.model.name ?? "Cámara")
                        .font(Theme.display(32))
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
                    HStack {
                        Button("Volver") { model.backToCameras() }
                            .controlSize(.large)
                        Button("Reintentar") { model.retry() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .keyboardShortcut(.defaultAction)
                        Spacer()
                        OpenLogLink()
                    }
                } else {
                    HStack(alignment: .firstTextBaseline) {
                        Label("Mientras dure la conexión, tu Mac usa el Wi-Fi de la cámara y queda sin Internet por Wi-Fi; al desconectar vuelve a tu red. Para seguir con Internet, conectá el Mac por Ethernet o el iPhone por cable con Compartir Internet.",
                              systemImage: "wifi.exclamationmark")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: Theme.s4)
                        Button("Cancelar") { model.cancelConnect() }
                            .controlSize(.large)
                            .keyboardShortcut(.cancelAction)
                    }
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
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
            Text("Contraseña Wi-Fi de la cámara")
                .font(.headline)
            Text("La cámara no la envió por Bluetooth. La encontrás en su pantalla, en Ajustes › Conexión inalámbrica (red \(ssid)).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                SecureField("Contraseña", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submitPassword)
                Button("Continuar", action: submitPassword)
                    .buttonStyle(.borderedProminent)
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
            VStack(spacing: 0) {
                icon
                    .frame(width: 26, height: 26)
                if !isLast {
                    Rectangle()
                        .fill(state == .done ? Theme.accent.opacity(0.5) : Theme.hairline)
                        .frame(width: 2)
                        .frame(minHeight: 18, maxHeight: .infinity)
                        .padding(.vertical, 2)
                }
            }
            VStack(alignment: .leading, spacing: Theme.s1) {
                Text(stage.title)
                    .font(.body.weight(state == .active ? .semibold : .regular))
                    .foregroundStyle(state == .pending ? .secondary : .primary)
                if let detail, !detail.isEmpty, state == .active || state == .failed {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                }
                if let progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 280)
                }
            }
            .padding(.top, 3)
            .padding(.bottom, isLast ? 0 : Theme.s3)
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var icon: some View {
        switch state {
        case .pending:
            Circle().strokeBorder(Theme.hairline, lineWidth: 2)
        case .active:
            ZStack {
                Circle().fill(Theme.accent.opacity(0.15))
                ProgressView().controlSize(.small)
            }
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(Theme.accent)
                .transition(.scale.combined(with: .opacity))
        case .failed:
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 22))
                .foregroundStyle(.red)
        }
    }
}

/// The one step only the user can do.
private struct ApprovalCallout: View {
    @State private var nudge = false

    var body: some View {
        HStack(spacing: Theme.s3) {
            Image(systemName: "hand.tap.fill")
                .font(.system(size: 26))
                .foregroundStyle(Theme.accent)
                .offset(y: nudge ? -2 : 2)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: nudge)
            VStack(alignment: .leading, spacing: 2) {
                Text("Aprobá la conexión en la cámara")
                    .font(.headline)
                Text("En la pantalla de la cámara aparece un pedido de emparejamiento: tocá el visto para aceptar. Solo hace falta la primera vez.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.radiusL, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusL, style: .continuous).strokeBorder(Theme.accent.opacity(0.35)))
        .onAppear { nudge = true }
    }
}

struct OpenLogLink: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Ver registro técnico") { openWindow(id: "log") }
            .buttonStyle(.link)
    }
}
