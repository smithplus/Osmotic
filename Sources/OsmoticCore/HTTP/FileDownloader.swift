import Foundation

/// Streams camera files to disk with resume.
///
/// The camera closes long transfers periodically and answers `404`/`500` transiently while busy, so a
/// download is a loop of Range requests with backoff, ended only by a run of attempts that moved no
/// bytes at all — the policy Osmosis arrived at on real hardware (a 1.14 GB clip off a Nano's dock SD
/// took six attempts). Bytes land in `<name>.part` and are renamed into place only when complete.
public final class FileDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    public enum Result: Sendable, Equatable {
        case saved(URL)
        case skipped(URL)
        case paused(bytes: Int)
        case cancelled
        case failed(String)
    }

    private enum Attempt { case done, interrupted, rangeIgnored, failed(Int) }

    /// Total attempts per file, productive or not — a runaway guard.
    static let maxAttempts = 20
    /// Consecutive zero-byte attempts before calling the transfer stalled.
    static let maxBarren = 5
    static let backoff: TimeInterval = 0.75

    private let http: CameraHTTP
    private let log: @Sendable (String) -> Void
    private var session: URLSession!
    private let lock = NSLock()
    private var handlers: [Int: TaskState] = [:]
    /// Tasks that completed before their handler was registered (a cancel racing the start).
    private var completedEarly: Set<Int> = []

    private final class TaskState {
        let handle: FileHandle
        let rangeStart: Int
        var written: Int
        var outcome: Attempt?
        let progress: (Int) -> Void
        let done: (Attempt) -> Void
        var lastReport = Date.distantPast

        init(handle: FileHandle, rangeStart: Int, progress: @escaping (Int) -> Void, done: @escaping (Attempt) -> Void) {
            self.handle = handle
            self.rangeStart = rangeStart
            self.written = rangeStart
            self.progress = progress
            self.done = done
        }
    }

    public init(http: CameraHTTP, log: @escaping @Sendable (String) -> Void) {
        self.http = http
        self.log = log
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60 * 60 * 6
        config.httpMaximumConnectionsPerHost = 2
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.waitsForConnectivity = false
        config.connectionProxyDictionary = [:]
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }

    /// Download `urlPath` to `destination`. `expectedSize` (from the manifest) of 0 means unknown.
    /// `progress` receives the file's running byte count, throttled.
    public func download(urlPath: String, to destination: URL, expectedSize: Int,
                         progress: @escaping @Sendable (Int) -> Void) async -> Result {
        let fm = FileManager.default
        // Only complete files are ever renamed into place, so presence alone proves it (the manifest
        // size can disagree slightly with the stored bytes, so it is not compared).
        if fm.fileExists(atPath: destination.path) { return .skipped(destination) }
        let part = destination.appendingPathExtension("part")
        do {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            return .failed("no se pudo crear la carpeta: \(error.localizedDescription)")
        }
        if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: nil) }

        func partSize() -> Int { (try? fm.attributesOfItem(atPath: part.path)[.size] as? Int) ?? 0 }
        func finish() -> Result {
            do {
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.moveItem(at: part, to: destination)
                return .saved(destination)
            } catch {
                return .failed("no se pudo guardar: \(error.localizedDescription)")
            }
        }

        if expectedSize > 0 && partSize() >= expectedSize { return finish() }
        if partSize() > 0 { log("resuming \(destination.lastPathComponent) at \(partSize() / 1_000_000) MB") }

        var attempt = 0
        var barren = 0
        while true {
            if Task.isCancelled { return .cancelled }
            let offset = partSize()
            let outcome = await fetch(urlPath: urlPath, into: part, from: offset, progress: progress)
            if Task.isCancelled { return .cancelled }
            var after = partSize()
            if case .rangeIgnored = outcome {
                if let h = try? FileHandle(forWritingTo: part) { try? h.truncate(atOffset: 0); try? h.close() }
                after = 0
                log("camera ignored the resume range — restarting \(destination.lastPathComponent) from 0")
            }
            // URLSession fails a body shorter than its Content-Length, so a clean finish is complete.
            if case .done = outcome { return finish() }
            if expectedSize > 0 && after >= expectedSize { return finish() }

            barren = after > offset ? 0 : barren + 1
            if barren >= Self.maxBarren || attempt >= Self.maxAttempts {
                log("paused \(destination.lastPathComponent) at \(after / 1_000_000) MB")
                return .paused(bytes: after)
            }
            attempt += 1
            let wait = Self.backoff * Double(max(1, barren))
            let what: String
            switch outcome {
            case .failed(let code): what = "camera refused (HTTP \(code))"
            case .rangeIgnored: what = "range ignored"
            default: what = "link dropped"
            }
            log("\(what) at \(after / 1_000_000) MB — resuming \(destination.lastPathComponent) in \(Int(wait * 1000)) ms (attempt \(attempt + 1))")
            try? await Task.sleep(for: .seconds(wait))
        }
    }

    /// One HTTP attempt, appending to `part` from `offset`.
    private func fetch(urlPath: String, into part: URL, from offset: Int,
                       progress: @escaping @Sendable (Int) -> Void) async -> Attempt {
        guard let handle = try? FileHandle(forWritingTo: part) else { return .failed(-1) }
        do { try handle.seek(toOffset: UInt64(offset)) } catch { try? handle.close(); return .failed(-1) }
        var req = http.request(urlPath)
        // A socket the camera cut must never be reused for the next attempt.
        req.setValue("close", forHTTPHeaderField: "Connection")
        if offset > 0 { req.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }

        let task = session.dataTask(with: req)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Attempt, Never>) in
                let state = TaskState(handle: handle, rangeStart: offset, progress: progress) { outcome in
                    try? handle.close()
                    cont.resume(returning: outcome)
                }
                let early = lock.withLock { () -> Bool in
                    if completedEarly.remove(task.taskIdentifier) != nil { return true }
                    handlers[task.taskIdentifier] = state
                    return false
                }
                if early { state.done(.interrupted) } else { task.resume() }
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func state(_ task: URLSessionTask) -> TaskState? {
        lock.withLock { handlers[task.taskIdentifier] }
    }

    // ---- URLSessionDataDelegate (serial delegate queue) -------------------------------------------

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let st = state(dataTask) else { completionHandler(.cancel); return }
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        if !(200...299).contains(code) {
            st.outcome = .failed(code)
            completionHandler(.cancel)
            return
        }
        if st.rangeStart > 0 && code != 206 {
            st.outcome = .rangeIgnored
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let st = state(dataTask) else { return }
        do {
            try st.handle.write(contentsOf: data)
            st.written += data.count
            let now = Date()
            if now.timeIntervalSince(st.lastReport) > 0.15 {
                st.lastReport = now
                st.progress(st.written)
            }
        } catch {
            st.outcome = .failed(-2)
            dataTask.cancel()
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let st = lock.withLock({ () -> TaskState? in
            let st = handlers.removeValue(forKey: task.taskIdentifier)
            if st == nil { completedEarly.insert(task.taskIdentifier) }
            return st
        }) else { return }
        st.progress(st.written)
        if let outcome = st.outcome {
            st.done(outcome)
        } else if let error {
            log("download error: \(error.localizedDescription)")
            st.done(.interrupted)
        } else {
            st.done(.done)
        }
    }
}
