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

    /// The transfer display: an LCD set into the plate, with its keys beside it.
    private func active(_ t: AppModel.TransferState) -> some View {
        HStack(spacing: Theme.s3) {
            LCDGlass {
                HStack(spacing: Theme.s4) {
                    VStack(alignment: .leading, spacing: 4) {
                        LCDText(text: "DESCARGANDO", size: 9.5, weight: .bold, color: Theme.lcdText.opacity(0.55))
                        LCDText(text: t.current?.name ?? "PREPARANDO…", size: 11.5)
                    }
                    .frame(width: 250, alignment: .leading)
                    VStack(alignment: .leading, spacing: 6) {
                        SegmentMeter(value: t.fraction, segments: 44).frame(height: 10)
                        HStack(spacing: Theme.s3) {
                            LCDText(text: "\(Int((t.fraction * 100).rounded()))%", size: 13, weight: .bold)
                            LCDText(text: String(format: "%02d/%02d", min(t.done + 1, t.total), t.total), size: 11,
                                    color: Theme.lcdText.opacity(0.75))
                            if t.speed > 0 {
                                LCDText(text: Format.bytes(Int(t.speed)).uppercased() + "/S", size: 11, color: Theme.lcdText.opacity(0.75))
                            }
                            if let eta = t.eta { LCDText(text: "−" + Format.clock(eta), size: 11, color: Theme.lcdText.opacity(0.75)) }
                        }
                    }
                }
                .padding(.horizontal, Theme.s3)
                .padding(.vertical, 10)
            }
            Button("Cancelar") { model.cancelTransfers() }
                .buttonStyle(KeyButtonStyle(kind: .ghost))
        }
        .padding(.horizontal, Theme.s3)
        .padding(.bottom, Theme.s3)
    }

    private func finished(_ summary: String) -> some View {
        let ok = summary.hasPrefix("Listo")
        return HStack(spacing: Theme.s3) {
            LCDGlass {
                HStack(spacing: Theme.s3) {
                    LED(color: ok ? Theme.success : Theme.warning, state: .on)
                    LCDText(text: summary.uppercased(), size: 12, weight: .semibold)
                    Spacer()
                }
                .padding(.horizontal, Theme.s3)
                .padding(.vertical, 12)
            }
            Button("Mostrar en Finder") { model.openDownloadFolder() }
                .buttonStyle(.signalKey)
        }
        .padding(.horizontal, Theme.s3)
        .padding(.bottom, Theme.s3)
    }
}
