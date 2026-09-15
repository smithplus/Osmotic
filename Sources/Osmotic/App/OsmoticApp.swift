import AppKit
import SwiftUI

@main
struct OsmoticApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        // One window, one camera session: a Window, not a WindowGroup (no duplicate windows or tabs).
        Window("Osmotic", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 820, minHeight: 560)
                .tint(Theme.accent)
                // The faceplate is a physical material: it looks the same in light and dark mode.
                .preferredColorScheme(.dark)
                .onAppear { appDelegate.model = model }
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: 1120, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Task { await model.updater.check(userInitiated: true) } }
            }
            CommandMenu("Camera") {
                Button("Download New") { model.downloadNew() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(!model.isConnected || model.linkLost || model.workspace != .files || model.newNotQueued.isEmpty)
                Button("Download Selection") { model.downloadSelected() }
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(!model.isConnected || model.linkLost || model.workspace != .files || model.selection.isEmpty)
                Button("Select All") { model.selectAllVisible() }
                    .disabled(!model.isConnected)
                Button("Select New") { model.selectNew() }
                    .disabled(!model.isConnected || model.newFiles.isEmpty)
                Button("Preview") { model.previewSelection() }
                    .disabled(!model.isConnected || model.selection.isEmpty)
                Divider()
                Button("Open Downloads Folder") { model.openDownloadFolder() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("Disconnect") { model.requestDisconnect() }
                    .disabled(!model.isConnected)
            }
            CommandGroup(after: .windowList) {
                OpenLogButton()
            }
            CommandGroup(replacing: .help) {
                Link("Osmotic Help", destination: URL(string: "https://github.com/smithplus/Osmotic/blob/main/docs/GUIDE.md")!)
                Link("Report an Issue…", destination: URL(string: "https://github.com/smithplus/Osmotic/issues")!)
                Divider()
                OpenLogButton(shortcut: false)  // ⌥⌘L lives on the Window menu item
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }

        Window("Log", id: "log") {
            LogView()
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        .restorationBehavior(.disabled)
        .defaultSize(width: 820, height: 520)
    }
}

private struct OpenLogButton: View {
    @Environment(\.openWindow) private var openWindow
    var shortcut = true
    var body: some View {
        if shortcut {
            Button("Technical Log") { openWindow(id: "log") }
                .keyboardShortcut("l", modifiers: [.command, .option])
        } else {
            Button("Technical Log") { openWindow(id: "log") }
        }
    }
}

/// Quitting while connected must hand the camera back and put the Wi-Fi back first.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Debug aid: `OSMOTIC_SNAPSHOT=<file.png>` renders the main window to a PNG after a few seconds
        // (with `OSMOTIC_SNAPSHOT_QUIT=1` the app then quits). The app draws itself, so no screen
        // recording permission is involved.
        guard let path = ProcessInfo.processInfo.environment["OSMOTIC_SNAPSHOT"] else { return }
        let quit = ProcessInfo.processInfo.environment["OSMOTIC_SNAPSHOT_QUIT"] == "1"
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Double(ProcessInfo.processInfo.environment["OSMOTIC_SNAPSHOT_DELAY"] ?? "") ?? 3))
            guard let model = self.model else { return }
            // Where the window buttons sit (top-left, in points), since the render can't show them.
            if let window = NSApp.windows.first(where: { $0.standardWindowButton(.closeButton) != nil }) {
                let frames = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { type -> String? in
                    guard let b = window.standardWindowButton(type) else { return nil }
                    let r = b.convert(b.bounds, to: nil)
                    let h = window.frame.height
                    return "x \(Int(r.minX))…\(Int(r.maxX)) y \(Int(h - r.maxY))…\(Int(h - r.minY))"
                }
                log(
                    "snapshot: window buttons at \(frames.joined(separator: ", ")) (window \(Int(window.frame.width))×\(Int(window.frame.height)), content starts \(Int(window.frame.height - window.contentLayoutRect.maxY)) pt down)"
                )
            } else {
                log("snapshot: no window with buttons (\(NSApp.windows.map { "\(type(of: $0))" }))")
            }
            let renderer = ImageRenderer(
                content: SnapshotView().environment(model).tint(Theme.accent).environment(\.colorScheme, .dark))
            renderer.scale = 2
            guard let cg = renderer.cgImage else { return }
            let rep = NSBitmapImageRep(cgImage: cg)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            log("snapshot written to \(path)")
            if quit { NSApp.terminate(nil) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // On the cameras screen a Cancel or Disconnect may still be handing the Wi-Fi back.
        guard let model, model.screen != .cameras || model.restoringWifi || model.hasWifiWorkPending else {
            return .terminateNow
        }
        if model.transfer != nil {
            let alert = NSAlert()
            alert.messageText = String(localized: "Quit while files are downloading?")
            alert.informativeText = String(localized: "What already arrived stays saved; the rest resumes next time.")
            alert.addButton(withTitle: String(localized: "Quit"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        Task { @MainActor in
            // Wi-Fi must be back on the user's network before the app goes — a cancelled connect cleans
            // up in its own task, so cancel it and then wait for all of it.
            if model.screen == .connecting { model.cancelConnect() }
            if model.screen == .library { await model.disconnect() }
            await model.finishWifiWork()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
