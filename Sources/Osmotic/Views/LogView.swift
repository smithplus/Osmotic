import AppKit
import SwiftUI

/// The technical log, for diagnosing a camera that misbehaves. Everything here is also in the log file.
struct LogView: View {
    @State private var store = LogStore.shared
    @State private var filter = ""

    private var lines: [String] {
        filter.isEmpty ? store.lines : store.lines.filter { $0.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Filter", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Spacer()
                Button("Copy All") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.lines.joined(separator: "\n"), forType: .string)
                }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([logSink.url]) }
            }
            .padding(Theme.s2)
            Divider()
            ScrollViewReader { proxy in
                List(Array(lines.enumerated()), id: \.offset) { item in
                    Text(item.element)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .id(item.offset)
                        .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .onChange(of: store.lines.count) {
                    if filter.isEmpty, let last = lines.indices.last { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
    }
}
