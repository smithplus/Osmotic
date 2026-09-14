import OsmoticCore
import SwiftUI

/// The camera's card, newest first, grouped by day.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmDisconnect = false

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
            let title = groups[key]?.first?.captureDate.map(Format.day) ?? "Sin fecha"
            return DaySection(id: key, title: title, files: groups[key] ?? [])
        }
    }

    private let columns = [GridItem(.adaptive(minimum: 196, maximum: 280), spacing: Theme.s3, alignment: .top)]

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            TopPlate {
                LED(color: model.linkLost ? Theme.danger : Theme.success,
                    state: model.linkLost ? .blink : .on,
                    label: model.linkLost ? (model.reconnecting ? "Reconectando" : "Sin señal") : "Enlazada")
            }
            ControlDeck(confirmDisconnect: $confirmDisconnect)
                .padding(.horizontal, Theme.s3)
                .padding(.bottom, Theme.s3)

            Group {
                if model.files.isEmpty {
                    trayMessage("La tarjeta está vacía", "No hay videos ni fotos en la cámara.")
                } else if model.visibleFiles.isEmpty {
                    trayMessage("Nada en «\(model.filter.rawValue)»", "Probá con otro filtro.")
                } else {
                    grid
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .recessed(radius: Theme.radiusL)
            .padding(.horizontal, Theme.s3)
            .padding(.bottom, Theme.s3)

            TransferBar()
        }
        // One sheet that stays up while ← / → change the file (sheet(item:) would re-present on each).
        .sheet(isPresented: Binding(get: { model.previewFile != nil },
                                    set: { if !$0 { model.previewFile = nil } })) {
            if let f = model.previewFile { PreviewView(file: f).environment(model) }
        }
        .confirmationDialog("¿Desconectar mientras se descargan archivos?", isPresented: $confirmDisconnect) {
            Button("Desconectar y cancelar la descarga", role: .destructive) { Task { await model.disconnect() } }
        } message: {
            Text("Lo que ya bajó queda guardado; lo demás se reanuda la próxima vez.")
        }
    }

    private func trayMessage(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
            Text(detail).font(.callout).foregroundStyle(Theme.muted)
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.s3, pinnedViews: [.sectionHeaders]) {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.files) { f in
                            MediaCell(file: f)
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
                    Silk("Cargando archivos más antiguos")
                }
                .padding(.bottom, Theme.s4)
                .onAppear { model.loadMoreIfNeeded() }
            }
        }
        .scrollContentBackground(.hidden)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusL, style: .continuous))
        .focusable()
        .focusEffectDisabled()
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

/// The deck above the tray: status display, filter keys, action keys.
struct ControlDeck: View {
    @Environment(AppModel.self) private var model
    @Binding var confirmDisconnect: Bool

    var body: some View {
        HStack(alignment: .center, spacing: Theme.s4) {
            StatusDisplay()
                .frame(width: 300)
            FilterKeys()
            Spacer(minLength: 0)
            actionKeys
        }
    }

    @ViewBuilder private var actionKeys: some View {
        HStack(spacing: Theme.s2) {
            if !model.selection.isEmpty {
                Button("Limpiar") { model.selection = [] }
                    .buttonStyle(KeyButtonStyle(kind: .ghost))
                Button("Bajar \(model.selection.count)") { model.downloadSelected() }
                    .buttonStyle(.signalKey)
                    .help("Descargar la selección (⌘D)")
            } else {
                Button(model.newFiles.isEmpty ? "Todo bajado" : "Bajar \(model.newFiles.count) nuevos") { model.downloadNew() }
                    .buttonStyle(.signalKey)
                    .disabled(model.newFiles.isEmpty)
                    .help("Baja todo lo que todavía no está en tu carpeta (⇧⌘D)")
            }
            Button {
                if model.transfer != nil { confirmDisconnect = true } else { Task { await model.disconnect() } }
            } label: {
                Image(systemName: "eject.fill").font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(KeyButtonStyle(kind: .ink))
            .help("Expulsar: libera la cámara y devuelve el Mac a tu Wi-Fi")
        }
    }
}

/// The deck's LCD: camera, library counts, battery and card.
private struct StatusDisplay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.status
        LCDGlass {
            VStack(alignment: .leading, spacing: 5) {
                LCDText(text: (model.target?.model.name ?? "OSMO").uppercased(), size: 10, weight: .bold,
                        color: Theme.lcdText.opacity(0.55))
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    LCDText(text: String(format: "%03d", model.files.count), size: 20, weight: .bold, ghost: 3)
                    LCDText(text: "ARCH", size: 10, color: Theme.lcdText.opacity(0.55))
                    LCDText(text: String(format: "%03d", model.newFiles.count), size: 20, weight: .bold, ghost: 3)
                    LCDText(text: "NUEVOS", size: 10, color: Theme.lcdText.opacity(0.55))
                }
                HStack(spacing: 12) {
                    LCDText(text: s.batteryPercent >= 0 ? "BAT \(s.batteryPercent)%" : "BAT --", size: 10.5,
                            color: (0...15).contains(s.batteryPercent) ? Theme.danger : Theme.lcdText.opacity(0.8))
                    if let st = s.displayStorage {
                        LCDText(text: "SD " + Format.compact(bytes: st.freeMb * 1_048_576) + " LIBRE", size: 10.5,
                                color: Theme.lcdText.opacity(0.8))
                    }
                }
            }
            .padding(.horizontal, Theme.s3)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Filter keys in a milled strip, with an LED over the active one — like a device's mode keys.
private struct FilterKeys: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            ForEach(AppModel.Filter.allCases) { f in
                VStack(spacing: 6) {
                    LED(color: Theme.accent, state: model.filter == f ? .on : .off, size: 6)
                    Button(f.rawValue) { model.filter = f }
                        .buttonStyle(KeyButtonStyle(kind: .ghost, compact: true))
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .recessed(radius: Theme.radiusM)
    }
}

struct SectionHeader: View {
    @Environment(AppModel.self) private var model
    let title: String
    let files: [CameraFile]

    var body: some View {
        let pending = files.filter { !model.isDownloaded($0) }
        HStack(alignment: .center, spacing: Theme.s2) {
            Silk(title, color: Theme.ink, size: 10.5)
            Text(String(format: "%02d", files.count))
                .font(Theme.readout(10, weight: .bold))
                .foregroundStyle(Theme.accent)
            EngravedRule()
            if !pending.isEmpty {
                Button("Bajar día") { model.enqueue(pending) }
                    .buttonStyle(.ghostKey)
            }
        }
        .padding(.vertical, Theme.s2)
        .padding(.horizontal, Theme.s1)
        .background(Theme.recess.opacity(0.96))
    }
}

/// Battery and free space, from the camera's own status pushes.
struct CameraStatusPill: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.status
        HStack(spacing: Theme.s3) {
            LED(color: model.linkLost ? Theme.danger : Theme.success, state: model.linkLost ? .blink : .on)
            if s.batteryPercent >= 0 {
                Readout(label: s.charging ? "BAT ⚡︎" : "BAT", value: "\(s.batteryPercent)%",
                        alert: s.batteryPercent <= 15)
            }
            if let st = s.displayStorage {
                Readout(label: "SD", value: Format.megabytes(st.freeMb).uppercased(), alert: false)
                    .help("\(Format.megabytes(st.freeMb)) libres de \(Format.megabytes(st.totalMb))")
            }
        }
        .padding(.horizontal, Theme.s2)
    }

}

/// `BAT 76%` — a silkscreen label over a mono value.
struct Readout: View {
    let label: String
    let value: String
    let alert: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Silk(label, size: 9.5)
            Text(value)
                .font(Theme.readout(12.5, weight: .bold))
                .foregroundStyle(alert ? Theme.danger : Theme.ink)
        }
    }
}
