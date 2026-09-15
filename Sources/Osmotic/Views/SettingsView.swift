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
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            UpdatesPane().tabItem { Label("Updates", systemImage: "arrow.down.circle") }
            CreditsPane().tabItem { Label("Credits", systemImage: "heart") }
        }
        .frame(width: 580)
    }

    private var general: some View {
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
                Toggle("Go back to your Wi-Fi when disconnecting", isOn: $restoreWifi)
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

/// Settings › Updates: version, automatic checks, and installing a newer release from GitHub.
private struct UpdatesPane: View {
    @Environment(AppModel.self) private var model
    @State private var automatic = true

    var body: some View {
        let updater = model.updater
        Form {
            Section {
                LabeledContent("Version") { Text(verbatim: updater.currentVersion.description) }
                Toggle("Check for updates automatically", isOn: $automatic)
                    .onChange(of: automatic) { updater.checkAutomatically = automatic }
                LabeledContent("Status") {
                    HStack {
                        Text(statusText(updater.state)).foregroundStyle(.secondary)
                        Spacer()
                        switch updater.state {
                        case .available(let r):
                            Button(updater.canInstall ? "Install \(r.version.description)" : "Open Release Page") {
                                Task { await updater.install(r) }
                            }
                            .disabled(model.screen != .cameras)
                        case .checking, .downloading:
                            ProgressView().controlSize(.small)
                        default:
                            Button("Check Now") { Task { await updater.check(userInitiated: true) } }
                        }
                    }
                }
                if case .available = updater.state, model.screen != .cameras {
                    Text("Disconnect from the camera to install.").font(.callout).foregroundStyle(.secondary)
                }
            } footer: {
                Text(
                    "Osmotic asks GitHub (api.github.com) for the latest release; nothing about you or your camera is sent. Updates are installed only when their signature matches the key built into this app."
                )
                .font(.footnote).foregroundStyle(.secondary)
            }
            if case .available(let r) = updater.state, !r.notes.isEmpty {
                Section("What’s new in \(r.version.description)") {
                    Text(verbatim: r.notes).font(.callout).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { automatic = updater.checkAutomatically }
    }

    private func statusText(_ s: UpdateService.State) -> String {
        switch s {
        case .idle:
            model.updater.lastChecked.map { String(localized: "Last checked \($0.formatted(.relative(presentation: .named)))") }
                ?? String(localized: "Not checked yet")
        case .checking: String(localized: "Checking…")
        case .upToDate: String(localized: "Osmotic is up to date.")
        case .available(let r): String(localized: "Osmotic \(r.version.description) is available.")
        case .downloading(let r): String(localized: "Downloading \(r.version.description)…")
        case .failed(let why): why
        }
    }
}

/// Settings › Credits: the people whose code and research Osmotic is built on.
private struct CreditsPane: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Made by") {
                    Link(destination: URL(string: "https://x.com/smithplus")!) { Text(verbatim: "smithplus") }
                }
                Text("Osmotic stands on the work of people who opened up DJI’s cameras when DJI didn’t. Thank you.")
                    .font(.callout)
            }
            section("Code", Credits.code)
            section("Protocol research", Credits.research)
            section("Testers", Credits.testers)
            Section {
                Link("Osmotic on GitHub", destination: URL(string: "https://github.com/smithplus/Osmotic")!)
                Text("MIT License. Not affiliated with DJI.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func section(_ title: LocalizedStringKey, _ entries: [Credits.Entry]) -> some View {
        Section(title) {
            ForEach(entries) { e in
                VStack(alignment: .leading, spacing: 2) {
                    Link(e.name, destination: e.url).fontWeight(.semibold)
                    Text(verbatim: e.work).font(.callout).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
