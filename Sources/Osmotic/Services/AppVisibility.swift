import AppKit
import SwiftUI

/// Whether any part of the app's window is on screen. Blinking lights, scan bars, the Bluetooth scan
/// and the webcam preview stop while it isn't — an idle, hidden app should cost nothing.
@Observable
final class AppVisibility {
    static let shared = AppVisibility()
    private(set) var visible = true
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        let nc = NotificationCenter.default
        for name in [
            NSApplication.didChangeOcclusionStateNotification, NSApplication.didHideNotification,
            NSApplication.didUnhideNotification,
        ] {
            observers.append(
                nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.update() }
                })
        }
    }

    private func update() {
        let now = NSApp.occlusionState.contains(.visible) && !NSApp.isHidden
        if now != visible { visible = now }
    }
}
