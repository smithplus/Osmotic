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
            Section("Descargas") {
                LabeledContent("Carpeta") {
                    HStack {
                        Text(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Cambiar…", action: chooseFolder)
                        if folder != Preferences.defaultDownloadFolder {
                            Button("Restablecer") { setFolder(Preferences.defaultDownloadFolder) }
                        }
                    }
                }
                Toggle("Organizar en subcarpetas por fecha (AAAA-MM-DD)", isOn: $byDate)
                    .onChange(of: byDate) { Preferences.organizeByDate = byDate }
                Toggle("Incluir RAW (.DNG) y audio de respaldo (.WAV) cuando existan", isOn: $sidecars)
                    .onChange(of: sidecars) { Preferences.includeSidecars = sidecars }
                Toggle("Sonido y aviso al terminar de descargar", isOn: $notifyWhenDone)
                    .onChange(of: notifyWhenDone) { Preferences.notifyWhenDone = notifyWhenDone }
            }
            Section("Conexión") {
                Toggle("Volver a mi Wi-Fi al desconectar", isOn: $restoreWifi)
                    .onChange(of: restoreWifi) { Preferences.restoreWifi = restoreWifi }
                Toggle("Desconectar automáticamente al terminar de descargar", isOn: $disconnectWhenDone)
                    .onChange(of: disconnectWhenDone) { Preferences.disconnectWhenDone = disconnectWhenDone }
            }
            Section("Mantenimiento") {
                LabeledContent("Cámaras guardadas") {
                    Button("Olvidar todas…") { confirmForget = true }
                        .disabled(model.savedCameras.isEmpty)
                }
                LabeledContent("Registro técnico") {
                    Button("Abrir carpeta") { NSWorkspace.shared.open(logSink.directory) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .confirmationDialog("¿Olvidar las cámaras guardadas?", isPresented: $confirmForget) {
            Button("Olvidar", role: .destructive) {
                for c in model.savedCameras { SavedCameraStore.remove(c.id) }
            }
        } message: {
            Text("La próxima vez vas a tener que buscarlas de nuevo. El historial de descargas se mantiene.")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        panel.prompt = "Elegir"
        if panel.runModal() == .OK, let url = panel.url { setFolder(url) }
    }

    private func setFolder(_ url: URL) {
        Preferences.downloadFolder = url
        folder = url
    }
}
