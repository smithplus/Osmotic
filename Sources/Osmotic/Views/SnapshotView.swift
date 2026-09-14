import SwiftUI

/// Debug-only: the current screen laid out flat (no scroll views) so `ImageRenderer` can draw it to a
/// PNG for visual review without hardware or screen recording.
struct SnapshotView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            switch model.screen {
            case .library:
                LibraryTopPlate()
                if model.workspace == .camera {
                    CameraControlView(snapshotStill: model.visibleFiles.first.flatMap { model.cachedThumbnail(for: $0) })
                        .padding(.horizontal, Theme.s3)
                        .padding(.bottom, Theme.s3)
                        .frame(maxHeight: .infinity, alignment: .top)
                } else {
                ControlDeck()
                    .padding(.horizontal, Theme.s3)
                    .padding(.bottom, Theme.s3)
                LibraryGridSnapshot()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .recessed(radius: Theme.radiusL)
                    .padding(.horizontal, Theme.s3)
                    .padding(.bottom, Theme.s3)
                }
                TransferBar()
            case .connecting:
                ConnectingView(scrolls: false)
            case .cameras:
                CamerasView(scrolls: false)
            }
        }
        .frame(width: 1120, height: 740, alignment: .top)
        .background { AluminumPlate() }
        .clipped()
    }
}

private struct LibraryGridSnapshot: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let columns = [GridItem(.adaptive(minimum: 196, maximum: 280), spacing: Theme.s3, alignment: .top)]
        VStack(spacing: 0) {
            if let first = model.visibleFiles.first {
                SectionHeader(title: first.captureDate.map(Format.day) ?? "", files: Array(model.visibleFiles.prefix(10)))
                    .padding(.horizontal, Theme.s3)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.s3) {
                ForEach(model.visibleFiles.prefix(10)) { MediaCell(file: $0) }
            }
            .padding(.horizontal, Theme.s3)
        }
    }
}
