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
            if model.linkLost { linkLostBanner }
            if model.files.isEmpty {
                ContentUnavailableView("La tarjeta está vacía", systemImage: "sdcard",
                                       description: Text("No hay videos ni fotos en la cámara."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.visibleFiles.isEmpty {
                ContentUnavailableView("Nada en «\(model.filter.rawValue)»", systemImage: "line.3.horizontal.decrease.circle",
                                       description: Text("Probá con otro filtro."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                grid
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { TransferBar() }
        .toolbar { toolbar }
        .navigationTitle(model.target?.model.name ?? "Osmotic")
        .navigationSubtitle(subtitle)
        .sheet(item: $model.previewFile) { f in
            PreviewView(file: f).environment(model)
        }
        .confirmationDialog("¿Desconectar mientras se descargan archivos?", isPresented: $confirmDisconnect) {
            Button("Desconectar y cancelar la descarga", role: .destructive) { Task { await model.disconnect() } }
        } message: {
            Text("Lo que ya bajó queda guardado; lo demás se reanuda la próxima vez.")
        }
    }

    private var subtitle: String {
        let n = model.files.count
        let new = model.newFiles.count
        var parts = ["\(n) archivo\(n == 1 ? "" : "s")\(model.moreAvailable ? "+" : "")"]
        if new > 0 { parts.append("\(new) nuevo\(new == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
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
            .padding(.horizontal, Theme.s4)
            .padding(.bottom, Theme.s4)
            if model.moreAvailable || model.loadingMore {
                HStack(spacing: Theme.s2) {
                    ProgressView().controlSize(.small)
                    Text("Cargando archivos más antiguos…").foregroundStyle(.secondary)
                }
                .padding(.bottom, Theme.s5)
                .onAppear { model.loadMoreIfNeeded() }
            }
        }
        .contentMargins(.top, Theme.s2, for: .scrollContent)
        .onKeyPress(.escape) {
            model.selection = []
            return .handled
        }
    }

    private var linkLostBanner: some View {
        HStack(spacing: Theme.s3) {
            if model.reconnecting {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "wifi.slash").foregroundStyle(.orange)
            }
            Text(model.reconnecting
                 ? "Reconectando con la cámara… la descarga sigue sola cuando vuelva."
                 : "La cámara dejó de responder (¿se apagó o se alejó?).")
                .font(.callout)
            Spacer()
            Button("Desconectar") { Task { await model.disconnect() } }
        }
        .padding(.horizontal, Theme.s4)
        .padding(.vertical, Theme.s2)
        .background(Color.orange.opacity(0.12))
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            CameraStatusPill()
        }
        ToolbarItem(placement: .principal) {
            @Bindable var model = model
            Picker("Filtro", selection: $model.filter) {
                ForEach(AppModel.Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if !model.selection.isEmpty {
                Button {
                    model.downloadSelected()
                } label: {
                    Label("Descargar \(model.selection.count)", systemImage: "arrow.down.circle")
                }
                .help("Descargar los archivos seleccionados (⌘D)")
            }
            Button {
                model.downloadNew()
            } label: {
                Label(model.newFiles.isEmpty ? "Todo descargado" : "Descargar \(model.newFiles.count) nuevos",
                      systemImage: model.newFiles.isEmpty ? "checkmark.circle" : "arrow.down.to.line")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.newFiles.isEmpty)
            .help("Baja todo lo que todavía no está en tu carpeta (⇧⌘D)")

            Button {
                if model.transfer != nil { confirmDisconnect = true } else { Task { await model.disconnect() } }
            } label: {
                Label("Desconectar", systemImage: "eject")
            }
            .help("Libera la cámara y devuelve el Mac a tu Wi-Fi")
        }
    }
}

private struct SectionHeader: View {
    @Environment(AppModel.self) private var model
    let title: String
    let files: [CameraFile]

    var body: some View {
        let pending = files.filter { !model.isDownloaded($0) }
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.weight(.semibold))
            Text("\(files.count)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            if !pending.isEmpty {
                Button("Descargar día") { model.enqueue(pending) }
                    .buttonStyle(.link)
                    .font(.callout)
            }
        }
        .padding(.vertical, Theme.s2)
        .padding(.horizontal, Theme.s1)
        .background(.bar)
    }
}

/// Battery and free space, from the camera's own status pushes.
struct CameraStatusPill: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.status
        HStack(spacing: Theme.s3) {
            if s.batteryPercent >= 0 {
                Label("\(s.batteryPercent)%", systemImage: batterySymbol(s.batteryPercent, charging: s.charging))
                    .foregroundStyle(s.batteryPercent <= 15 ? .red : .primary)
            }
            if let st = s.displayStorage {
                Label("\(Format.megabytes(st.freeMb)) libres", systemImage: "sdcard")
                    .help("\(Format.megabytes(st.freeMb)) libres de \(Format.megabytes(st.totalMb))")
            }
        }
        .font(.callout.monospacedDigit())
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, Theme.s2)
    }

    private func batterySymbol(_ pct: Int, charging: Bool) -> String {
        if charging { return "battery.100percent.bolt" }
        switch pct {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}
