import Foundation
import Observation
import os

/// The app's diagnostic log. Every line goes to `~/Library/Logs/Osmotic/<session>.log` — so a test run
/// can be sent as a file — and to the in-memory ring the Log window shows.
///
/// `log(_:)` is callable from any thread; the datalink thread logs through it.
nonisolated func log(_ message: String) {
    let line = logSink.append(message)
    Task { @MainActor in LogStore.shared.append(line) }
}

nonisolated let logSink = FileSink.makeSessionLog()

@Observable
final class LogStore {
    static let shared = LogStore()
    private(set) var lines: [String] = []

    func append(_ line: String) {
        lines.append(line)
        if lines.count > 5000 { lines.removeFirst(lines.count - 5000) }
    }
}

/// Serialised, timestamped file writer.
final class FileSink: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "osmotic.log")
    private let handle: FileHandle?
    private let formatter: DateFormatter
    private let logger = Logger(subsystem: "io.github.smithplus.osmotic", category: "app")

    nonisolated static func makeSessionLog() -> FileSink {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Osmotic", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        prune(dir, keep: 20)
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        stamp.locale = Locale(identifier: "en_US_POSIX")
        return FileSink(url: dir.appendingPathComponent("osmotic-\(stamp.string(from: Date())).log"))
    }

    nonisolated init(url: URL) {
        self.url = url
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
    }

    nonisolated var directory: URL { url.deletingLastPathComponent() }

    nonisolated func append(_ message: String) -> String {
        let line = queue.sync { "\(formatter.string(from: Date())) \(message)" }
        logger.debug("\(line, privacy: .public)")
        queue.async { [handle] in
            if let data = (line + "\n").data(using: .utf8) { try? handle?.write(contentsOf: data) }
        }
        return line
    }

    nonisolated static func prune(_ dir: URL, keep: Int) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let logs = files.filter { $0.pathExtension == "log" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in logs.dropFirst(keep - 1) { try? fm.removeItem(at: old) }
    }
}
