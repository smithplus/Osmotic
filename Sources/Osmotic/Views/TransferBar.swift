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

    /// The transfer display: an LCD set into the plate, with its key beside it. Values sit in fixed
    /// columns under small legends so nothing jumps while the numbers change.
    private func active(_ t: AppModel.TransferState) -> some View {
        HStack(alignment: .bottom, spacing: Theme.s3) {
            LCDGlass {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: Theme.s4) {
                        LCDText(text: t.current?.name ?? String(localized: "Preparing…").uppercased(), size: 12, weight: .medium)
                            .truncationMode(.middle)
                        Spacer(minLength: Theme.s2)
                        LCDPair(label: "File", value: "\(min(t.done + 1, t.total))/\(t.total)")
                        if t.speed > 0 { LCDPair(label: "Speed", value: Format.bytes(Int(t.speed)).uppercased() + "/S") }
                        if let eta = t.eta { LCDPair(label: "Left", value: Format.clock(eta)) }
                        LCDText(text: "\(Int((t.fraction * 100).rounded()))%", size: 12, weight: .medium)
                            .frame(width: 44, alignment: .trailing)
                    }
                    SegmentMeter(value: t.fraction, segments: 60).frame(height: 5)
                }
                .padding(.horizontal, Theme.s3 + 2)
                .padding(.vertical, 12)
            }
            CassetteKeyBank {
                Button("Cancel") { model.cancelTransfers() }
                    .buttonStyle(CassetteKeyStyle(height: 40))
            }
            .fixedSize()
        }
        .padding(.horizontal, Theme.s3)
        .padding(.bottom, Theme.s3)
    }

    private func finished(_ summary: AppModel.TransferSummary) -> some View {
        HStack(alignment: .bottom, spacing: Theme.s3) {
            LCDGlass {
                HStack(spacing: Theme.s3) {
                    LED(color: summary.ok ? Theme.success : Theme.warning, state: .on)
                    LCDText(text: summary.text.uppercased(), size: 12, weight: .medium)
                    Spacer()
                }
                .padding(.horizontal, Theme.s3 + 2)
                .padding(.vertical, 14)
            }
            CassetteKeyBank {
                Button("Show in Finder") { model.openDownloadFolder() }
                    .buttonStyle(CassetteKeyStyle(finish: .orange, height: 40))
            }
            .fixedSize()
        }
        .padding(.horizontal, Theme.s3)
        .padding(.bottom, Theme.s3)
    }
}
