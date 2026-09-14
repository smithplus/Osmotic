import AppKit
import SwiftUI

@main
struct OsmoticApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Osmotic", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 760, minHeight: 540)
                .tint(Theme.accent)
                .onAppear { appDelegate.model = model }
        }
        .defaultSize(width: 1120, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Cámara") {
                Button("Descargar nuevos") { model.downloadNew() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(!model.isConnected || model.newFiles.isEmpty)
                Button("Descargar selección") { model.downloadSelected() }
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(!model.isConnected || model.selection.isEmpty)
                Divider()
                Button("Abrir carpeta de descargas") { model.openDownloadFolder() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("Desconectar") { Task { await model.disconnect() } }
                    .disabled(!model.isConnected)
            }
            CommandGroup(after: .windowList) {
                OpenLogButton()
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .tint(Theme.accent)
        }

        Window("Registro", id: "log") {
            LogView()
                .tint(Theme.accent)
        }
        .defaultSize(width: 820, height: 520)
    }
}

private struct OpenLogButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Registro técnico") { openWindow(id: "log") }
            .keyboardShortcut("l", modifiers: [.command, .option])
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
            let renderer = ImageRenderer(content: SnapshotView().environment(model).tint(Theme.accent))
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
        guard let model, model.screen != .cameras else { return .terminateNow }
        Task { @MainActor in
            if model.screen == .connecting { model.cancelConnect() }
            await model.disconnect()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
