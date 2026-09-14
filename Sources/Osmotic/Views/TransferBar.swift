import SwiftUI

/// The transfer in progress — or, once it ends, what happened.
struct TransferBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let t = model.transfer {
            active(t)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if let summary = model.lastTransferSummary {
            finished(summary)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// The LCD: black strip, orange segment meter, mono readouts.
    private func active(_ t: AppModel.TransferState) -> some View {
        HStack(spacing: Theme.s4) {
            VStack(alignment: .leading, spacing: 3) {
                Silk("Descargando", color: Theme.accent, size: 9.5)
                Text(t.current?.name ?? "PREPARANDO…")
                    .font(Theme.readout(12, weight: .semibold))
                    .foregroundStyle(Theme.lcdText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(width: 250, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                SegmentMeter(value: t.fraction, segments: 40)
                    .frame(height: 12)
                HStack(spacing: Theme.s3) {
                    lcd("\(Int((t.fraction * 100).rounded()))%", big: true)
                    lcd(String(format: "%02d/%02d", min(t.done + 1, t.total), t.total))
                    if t.speed > 0 { lcd("\(Format.bytes(Int(t.speed)).uppercased())/S") }
                    if let eta = t.eta { lcd("−" + Format.clock(eta)) }
                }
            }

            Button("Cancelar") { model.cancelTransfers() }
                .buttonStyle(KeyButtonStyle(kind: .ghost, compact: true))
        }
        .padding(.horizontal, Theme.s4)
        .padding(.vertical, Theme.s3)
        .background(Theme.lcd)
    }

    private func lcd(_ text: String, big: Bool = false) -> some View {
        Text(text)
            .font(Theme.readout(big ? 13 : 11.5, weight: big ? .bold : .medium))
            .foregroundStyle(big ? Theme.accent : Theme.lcdText.opacity(0.75))
    }

    private func finished(_ summary: String) -> some View {
        let ok = summary.hasPrefix("Listo")
        return HStack(spacing: Theme.s3) {
            LED(color: ok ? Theme.success : Theme.warning, label: ok ? "Listo" : "Atención")
            Text(summary)
                .font(Theme.readout(12, weight: .medium))
                .foregroundStyle(Theme.lcdText)
            Spacer()
            Button("Mostrar en Finder") { model.openDownloadFolder() }
                .buttonStyle(KeyButtonStyle(kind: .signal, compact: true))
        }
        .padding(.horizontal, Theme.s4)
        .padding(.vertical, Theme.s3)
        .background(Theme.lcd)
    }
}
