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

    private func active(_ t: AppModel.TransferState) -> some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.s2) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(Theme.accent)
                Text(t.current?.name ?? "Preparando…")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(stats(t))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("Cancelar") { model.cancelTransfers() }
                    .controlSize(.small)
            }
            ProgressView(value: t.fraction)
                .progressViewStyle(.linear)
                .tint(Theme.accent)
        }
        .padding(.horizontal, Theme.s4)
        .padding(.vertical, Theme.s3)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func stats(_ t: AppModel.TransferState) -> String {
        var parts = ["\(Int((t.fraction * 100).rounded())) %", "\(min(t.done + 1, t.total)) de \(t.total)"]
        if t.speed > 0 { parts.append("\(Format.bytes(Int(t.speed)))/s") }
        if let eta = t.eta { parts.append("faltan \(Format.eta(eta))") }
        return parts.joined(separator: " · ")
    }

    private func finished(_ summary: String) -> some View {
        HStack(spacing: Theme.s2) {
            Image(systemName: summary.hasPrefix("Listo") ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(summary.hasPrefix("Listo") ? Theme.success : .orange)
            Text(summary)
                .font(.callout)
            Spacer()
            Button("Mostrar en Finder") { model.openDownloadFolder() }
                .controlSize(.small)
        }
        .padding(.horizontal, Theme.s4)
        .padding(.vertical, Theme.s3)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
