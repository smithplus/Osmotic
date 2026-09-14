import SwiftUI

/// Debug-only: the current screen laid out flat (no scroll views, no window toolbar) so
/// `ImageRenderer` can draw it to a PNG for visual review without hardware or screen recording.
struct SnapshotView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            switch model.screen {
            case .library:
                HStack {
                    CameraStatusPill()
                    Spacer()
                    Text("\(model.newFiles.count) nuevos").foregroundStyle(.secondary)
                }
                .padding(Theme.s3)
                LibraryGridSnapshot()
                TransferBar()
            case .connecting:
                ConnectingView(scrolls: false)
            case .cameras:
                CamerasView(scrolls: false)
            }
        }
        .frame(width: 1120, height: model.screen == .library ? 1400 : 740, alignment: .top)
        .background(Theme.window)
    }
}

private struct LibraryGridSnapshot: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let columns = [GridItem(.adaptive(minimum: 196, maximum: 280), spacing: Theme.s3, alignment: .top)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.s3) {
            ForEach(model.visibleFiles.prefix(20)) { MediaCell(file: $0) }
        }
        .padding(.horizontal, Theme.s4)
        Spacer(minLength: 0)
    }
}
