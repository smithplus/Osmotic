import OsmoticCore
import SwiftUI

/// The camera's card, newest first, grouped by day.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var gridWidth: CGFloat = 800
    @FocusState private var gridFocused: Bool

    private struct DaySection: Identifiable {
        let id: String
        let title: String
        let files: [CameraFile]
    }

    private var sections: [DaySection] {
        var order: [String] = []
        var groups: [String: [CameraFile]] = [:]
        for f in model.visibleFiles {
            let key = String(f.timestamp.prefix(8))
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(f)
        }
        return order.map { key in
            let title = groups[key]?.first?.captureDate.map(Format.day) ?? String(localized: "No date")
            return DaySection(id: key, title: title, files: groups[key] ?? [])
        }
    }

    private let columns = [GridItem(.adaptive(minimum: 196, maximum: 280), spacing: Theme.s3, alignment: .top)]

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            LibraryTopPlate()
            if model.workspace == .webcam {
                WebcamView()
            } else if model.workspace == .camera {
                CameraControlView()
                    .padding(.horizontal, Theme.s3)
                    .padding(.bottom, Theme.s3)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                ControlDeck()
                    .padding(.horizontal, Theme.s3)
                    .padding(.bottom, Theme.s3)

                if let error = model.controlError {
                    // Why Live didn't open (downloads running, the camera refused capture mode).
                    ErrorBanner(message: error)
                        .padding(.horizontal, Theme.s3)
                        .padding(.bottom, Theme.s3)
                        .transition(.panelFromTop)
                        .task(id: error) {
                            try? await Task.sleep(for: .seconds(8))
                            model.dismissControlError(error)
                        }
                }
                if model.linkGaveUp {
                    HStack(spacing: Theme.s3) {
                        ErrorBanner(
                            message: String(
                                localized: "Lost contact with the camera. Check that it’s on and nearby, then reconnect."))
                        CassetteKeyBank {
                            Button("Reconnect") { model.reconnectLink() }
                                .buttonStyle(.primaryKey)
                            Button("Disconnect") { model.requestDisconnect() }
                                .buttonStyle(.secondaryKey)
                        }
                    }
                    .padding(.horizontal, Theme.s3)
                    .padding(.bottom, Theme.s3)
                    .transition(.panelFromTop)
                }

                Group {
                    if model.files.isEmpty {
                        trayMessage("The card is empty", "There are no videos or photos on the camera.")
                    } else if model.visibleFiles.isEmpty {
                        trayMessage("Nothing to show here", "Try another view.")
                    } else {
                        grid
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .recessed(radius: Theme.radiusL)
                .padding(.horizontal, Theme.s3)
                .padding(.bottom, Theme.s3)
            }

            TransferBar()
        }
        .motion(Motion.panel, value: model.linkGaveUp)
        .motion(Motion.panel, value: model.controlError)
        // One sheet that stays up while ← / → change the file (sheet(item:) would re-present on each).
        .sheet(
            isPresented: Binding(
                get: { model.previewFile != nil },
                set: { if !$0 { model.previewFile = nil } })
        ) {
            if let f = model.previewFile { PreviewView(file: f).environment(model) }
        }
        .confirmationDialog("Disconnect while files are downloading?", isPresented: $model.confirmingDisconnect) {
            Button("Disconnect and Cancel the Download", role: .destructive) { Task { await model.disconnect() } }
        } message: {
            Text("What already arrived stays saved; the rest resumes next time.")
        }
    }

    private func trayMessage(_ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
            Text(detail).font(.callout).foregroundStyle(Theme.muted)
        }
    }

    /// Columns the adaptive grid lays out at this width (same arithmetic as `GridItem.adaptive`).
    private var columnCount: Int {
        max(1, Int((gridWidth - Theme.s3 * 2 + Theme.s3) / (196 + Theme.s3)))
    }

    /// The grid as rows of ids: each day starts a new row, so ↑/↓ land where the eye expects.
    private var rows: [[String]] {
        sections.flatMap { section in
            stride(from: 0, to: section.files.count, by: columnCount).map { start in
                section.files[start..<min(start + columnCount, section.files.count)].map(\.id)
            }
        }
    }

    private func move(_ direction: MoveCommandDirection, proxy: ScrollViewProxy) {
        let rows = rows
        guard !rows.isEmpty else { return }
        let extend = NSEvent.modifierFlags.contains(.shift)
        guard let cur = model.cursor ?? model.visibleFiles.first(where: { model.selection.contains($0.id) })?.id,
            let r = rows.firstIndex(where: { $0.contains(cur) }), let c = rows[r].firstIndex(of: cur)
        else {
            model.moveCursor(to: rows[0][0], extend: false)
            proxy.scrollTo(rows[0][0])
            return
        }
        var target: String?
        switch direction {
        case .left: target = c > 0 ? rows[r][c - 1] : (r > 0 ? rows[r - 1].last : nil)
        case .right: target = c + 1 < rows[r].count ? rows[r][c + 1] : (r + 1 < rows.count ? rows[r + 1].first : nil)
        case .up: target = r > 0 ? rows[r - 1][min(c, rows[r - 1].count - 1)] : nil
        case .down: target = r + 1 < rows.count ? rows[r + 1][min(c, rows[r + 1].count - 1)] : nil
        @unknown default: target = nil
        }
        guard let target else { return }
        model.moveCursor(to: target, extend: extend)
        proxy.scrollTo(target)
    }

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.s3, pinnedViews: [.sectionHeaders]) {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.files) { f in
                                MediaCell(file: f, keyboardFocus: gridFocused && model.cursor == f.id)
                                    .simultaneousGesture(TapGesture().onEnded { gridFocused = true })
                                    .onAppear { if f.id == model.visibleFiles.last?.id { model.loadMoreIfNeeded() } }
                            }
                        } header: {
                            SectionHeader(title: section.title, files: section.files)
                        }
                    }
                }
                .padding(.horizontal, Theme.s3)
                .padding(.bottom, Theme.s3)
                if model.moreAvailable || model.loadingMore {
                    HStack(spacing: Theme.s2) {
                        LED(color: Theme.accent, state: .blink)
                        Silk("Loading older files")
                    }
                    .padding(.bottom, Theme.s4)
                    .onAppear { model.loadMoreIfNeeded() }
                }
            }
            .scrollContentBackground(.hidden)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusL, style: .continuous))
            .onGeometryChange(for: CGFloat.self) {
                $0.size.width
            } action: {
                gridWidth = $0
            }
            .focusable()
            .focused($gridFocused)
            .defaultFocus($gridFocused, true)
            // The grid's own focus is shown on the cell under the cursor, not as a ring round the tray.
            .focusEffectDisabled()
            .onMoveCommand { move($0, proxy: proxy) }
            .onKeyPress(.escape) {
                model.selection = []
                return .handled
            }
            .onKeyPress(.space) {
                guard !model.selection.isEmpty else { return .ignored }
                model.previewSelection()
                return .handled
            }
        }
    }
}

/// The three tabs on top: Files · Live · Webcam. Live needs a Wi-Fi connection; Webcam works from any
/// screen but the connection steps.
struct WorkspaceTabs: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        CassetteKeyBank(compact: true) {
            key("Files", .files, help: "The camera’s card")
            key("Live", .camera, help: "Record, take photos and see what the camera sees (over Wi-Fi)")
                .disabled(
                    model.screen != .library || model.linkLost || model.isTransferring
                        || model.target?.model.supportsLive != true)
            key("Webcam", .webcam, help: "Use the camera as a webcam over USB")
        }
        .disabled(model.switchingWorkspace)
    }

    private func key(_ title: LocalizedStringKey, _ w: AppModel.Workspace, help: LocalizedStringKey) -> some View {
        Button(title) { model.setWorkspace(w) }
            .buttonStyle(CassetteKeyStyle(compact: true, latched: model.workspace == w, width: 76))
            .accessibilityAddTraits(model.workspace == w ? .isSelected : [])
            .help(help)
    }
}

/// The library's top strip: the wordmark, the Files · Live · Webcam tabs in the middle, link LED and Disconnect on the right.
struct LibraryTopPlate: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TopPlate {
            WorkspaceTabs()
        } trailing: {
            HStack(spacing: Theme.s3) {
                LED(
                    color: model.linkLost ? Theme.danger : Theme.success,
                    state: model.linkLost || model.switchingWorkspace ? .blink : .on,
                    label: model.linkLost ? (model.reconnecting ? "Reconnecting" : "No signal") : "Linked")
                CassetteKeyBank(compact: true) {
                    SettingsKey()
                    Button {
                        model.requestDisconnect()
                    } label: {
                        Label("Disconnect", systemImage: "eject.fill")
                    }
                    .buttonStyle(.compactKey)
                    .help("Release the camera and put the Mac back on your Wi-Fi")
                }
            }
        }
    }
}

/// The deck above the tray: a full-width status display, then the view keys and the transfer keys —
/// two cassette-style banks with their legends printed above.
struct ControlDeck: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            StatusDisplay()
            HStack(alignment: .bottom, spacing: Theme.s4) {
                FilterKeys()
                Spacer(minLength: 0)
                actionKeys
            }
        }
    }

    private var actionKeys: some View {
        VStack(alignment: .leading, spacing: 6) {
            BankLegend(text: "Transfer")
            CassetteKeyBank {
                if !model.selection.isEmpty {
                    Button("Deselect") { model.selection = [] }
                        .buttonStyle(.secondaryKey)
                        .help("Deselect all (esc)")
                    Button("Download \(model.selection.count) selected") { model.downloadSelected() }
                        .buttonStyle(.primaryKey)
                        .disabled(model.linkLost)
                        .help("Download the selection (⌘D)")
                } else {
                    let pending = model.newNotQueued.count
                    Button {
                        model.downloadNew()
                    } label: {
                        if pending > 0 {
                            Text("Download \(pending) New")
                        } else if !model.queuedIds.isEmpty {
                            Text("All queued")
                        } else {
                            Text("All downloaded")
                        }
                    }
                    .buttonStyle(.primaryKey)
                    .disabled(pending == 0 || model.linkLost)
                    .help("Download everything that isn't in your folder yet (⇧⌘D)")
                }
            }
        }
        .fixedSize()
    }
}

/// The deck's LCD: one quiet line of `LABEL: value` readouts.
private struct StatusDisplay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.status
        LCDGlass {
            HStack(spacing: Theme.s4) {
                LCDText(text: (model.target?.model.name ?? String(localized: "Camera")).uppercased(), size: 12.5, weight: .medium)
                LCDPair(label: "Files", value: "\(model.files.count)")
                LCDPair(label: "New", value: "\(model.newFiles.count)")
                if !model.selection.isEmpty {
                    LCDPair(label: "Selected", value: "\(model.selection.count)")
                }
                Spacer(minLength: Theme.s2)
                LCDPair(
                    label: "Batt", value: s.batteryPercent >= 0 ? "\(s.batteryPercent)%" : "--",
                    color: (0...15).contains(s.batteryPercent) ? Theme.danger : Theme.lcdText)
                if let st = s.displayStorage {
                    LCDPair(label: "Free", value: Format.compact(bytes: st.freeMb * 1_048_576))
                        .help(String(localized: "\(Format.megabytes(st.freeMb)) free of \(Format.megabytes(st.totalMb))"))
                }
            }
            .padding(.horizontal, Theme.s3 + 2)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// View keys: a cassette bank where the chosen key stays latched down.
private struct FilterKeys: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            BankLegend(text: "Show")
            CassetteKeyBank {
                ForEach(AppModel.Filter.allCases) { f in
                    Button(f.title) { model.filter = f }
                        .buttonStyle(CassetteKeyStyle(latched: model.filter == f, width: 66))
                        .accessibilityAddTraits(model.filter == f ? .isSelected : [])
                }
            }
        }
        .fixedSize()
    }
}

struct SectionHeader: View {
    @Environment(AppModel.self) private var model
    let title: String
    let files: [CameraFile]

    var body: some View {
        let queued = model.queuedIds
        let pending = files.filter { !model.isDownloaded($0) && !queued.contains($0.id) }
        HStack(alignment: .center, spacing: Theme.s2) {
            Silk(verbatim: title, color: Theme.ink, size: 10.5)
            Text(String(format: "%02ld", files.count))
                .font(Theme.readout(10, weight: .bold))
                .foregroundStyle(Theme.accent)
            EngravedRule()
            if !pending.isEmpty {
                CassetteKeyBank(compact: true) {
                    Button("Download Day") { model.enqueue(pending) }
                        .buttonStyle(.compactKey)
                        .disabled(model.linkLost)
                        .accessibilityLabel(Text("Download \(title)"))
                }
            }
        }
        .padding(.vertical, Theme.s2)
        .padding(.horizontal, Theme.s1)
        .background(Theme.recess.opacity(0.96))
    }
}
