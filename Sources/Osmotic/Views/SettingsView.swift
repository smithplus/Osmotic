import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var folder = Preferences.downloadFolder
    @State private var byDate = Preferences.organizeByDate
    @State private var sidecars = Preferences.includeSidecars
    @State private var restoreWifi = Preferences.restoreWifi
    @State private var disconnectWhenDone = Preferences.disconnectWhenDone
    @State private var notifyWhenDone = Preferences.notifyWhenDone
    @State private var confirmForget = false

    var body: some View {
        Form {
            Section("Downloads") {
                LabeledContent("Folder") {
                    HStack {
                        Text(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Change…", action: chooseFolder)
                        if folder != Preferences.defaultDownloadFolder {
                            Button("Reset") { setFolder(Preferences.defaultDownloadFolder) }
                        }
                    }
                }
                Toggle("Sort into folders by date (YYYY-MM-DD)", isOn: $byDate)
                    .onChange(of: byDate) { Preferences.organizeByDate = byDate }
                Toggle("Include RAW (.DNG) and backup audio (.WAV) when present", isOn: $sidecars)
                    .onChange(of: sidecars) { Preferences.includeSidecars = sidecars }
                Toggle("Play a sound and notify when downloads finish", isOn: $notifyWhenDone)
                    .onChange(of: notifyWhenDone) { Preferences.notifyWhenDone = notifyWhenDone }
            }
            Section("Connection") {
                Toggle("Go back to my Wi-Fi when disconnecting", isOn: $restoreWifi)
                    .onChange(of: restoreWifi) { Preferences.restoreWifi = restoreWifi }
                Toggle("Disconnect automatically when downloads finish", isOn: $disconnectWhenDone)
                    .onChange(of: disconnectWhenDone) { Preferences.disconnectWhenDone = disconnectWhenDone }
            }
            Section("Maintenance") {
                LabeledContent("Saved cameras") {
                    Button("Forget All…") { confirmForget = true }
                        .disabled(model.savedCameras.isEmpty)
                }
                LabeledContent("Technical log") {
                    Button("Open Folder") { NSWorkspace.shared.open(logSink.directory) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .confirmationDialog("Forget the saved cameras?", isPresented: $confirmForget) {
            Button("Forget", role: .destructive) {
                for c in model.savedCameras { SavedCameraStore.remove(c.id) }
                model.refreshSavedCameras()
            }
        } message: {
            Text("Next time you’ll have to find them again. Your download history is kept.")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        panel.prompt = String(localized: "Choose")
        if panel.runModal() == .OK, let url = panel.url { setFolder(url) }
    }

    private func setFolder(_ url: URL) {
        Preferences.downloadFolder = url
        folder = url
    }
}
