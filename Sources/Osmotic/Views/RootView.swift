import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.screen {
            case .cameras: CamerasView()
            case .connecting: ConnectingView()
            case .library: LibraryView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { AluminumPlate().ignoresSafeArea() }
        .animation(.smooth(duration: 0.25), value: model.screen)
    }
}

/// The strip across the top of every screen: room for the window buttons, the printed wordmark,
/// and whatever status that screen wants on the right.
struct TopPlate<Trailing: View>: View {
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Theme.s3) {
            Spacer().frame(width: 64)   // traffic lights
            HStack(spacing: 6) {
                Text("osmotic")
                    .font(.system(size: 15, weight: .heavy))
                    .tracking(-0.3)
                    .foregroundStyle(Theme.ink)
                Circle().fill(Theme.accent).frame(width: 5, height: 5).offset(y: 3)
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, Theme.s3)
        .frame(height: 44)
    }
}
