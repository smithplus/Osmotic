import AppKit
import UserNotifications

/// "Your files are ready": a sound, a dock bounce, and a system notification when the app isn't in
/// front — a long transfer is exactly when the user has gone to do something else.
enum TransferNotifier {
    private static var asked = false

    /// Ask for notification permission the first time a transfer starts (not at launch).
    static func prepare() {
        guard Preferences.notifyWhenDone, !asked else { return }
        asked = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            log("notify: permission \(granted ? "granted" : "not granted")")
        }
    }

    static func finished(saved: Int, failed: Int, folder: URL) {
        guard Preferences.notifyWhenDone, saved > 0 || failed > 0 else { return }
        NSSound(named: failed == 0 ? "Glass" : "Basso")?.play()
        guard !NSApp.isActive else { return }
        NSApp.requestUserAttention(.informationalRequest)
        let content = UNMutableNotificationContent()
        content.title = failed == 0 ? "Descarga terminada" : "Descarga incompleta"
        content.body = failed == 0
            ? "\(saved) archivo\(saved == 1 ? "" : "s") en \(folder.lastPathComponent)"
            : "\(saved) bajaron, \(failed) no — abrí Osmotic para reintentar"
        let request = UNNotificationRequest(identifier: "transfer-\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
