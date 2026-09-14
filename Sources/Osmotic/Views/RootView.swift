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
        .background(Theme.window)
        .animation(.smooth(duration: 0.25), value: model.screen)
    }
}
