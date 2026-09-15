import Foundation

/// Streams camera files to disk with resume.
///
/// The camera closes long transfers periodically and answers `404`/`500` transiently while busy, so a
/// download is a loop of Range requests with backoff, ended only by a run of attempts that moved no
/// bytes at all — the policy Osmosis arrived at on real hardware (a 1.14 GB clip off a Nano's dock SD
/// took six attempts). Bytes land in `<name>.part` and are renamed into place only when complete.
///
/// `@unchecked Sendable`: `handlers` and `completedEarly` are guarded by `lock`; each `TaskState` is
/// only touched on the URLSession's serial delegate queue.
public final class FileDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    public enum Result: Sendable, Equatable {
        case saved(URL)
        case skipped(URL)
        case paused(bytes: Int)
        case cancelled
        case failed(String)
    }

    /// `total` is the file's full size as the server stated it (Content-Length of a 200, the
    /// `/TOTAL` of a 206 or 416 Content-Range), when it said.
    private enum Attempt {
        case done(total: Int?)
        case alreadyComplete
        case interrupted(total: Int?)
        case rangeIgnored
        case failed(Int)
    }

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
        var total: Int?
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
    public func download(
        urlPath: String, to destination: URL, expectedSize: Int,
        progress: @escaping @Sendable (Int) -> Void
    ) async -> Result {
        let fm = FileManager.default
        // Never write outside the folder we were given: the name must be a plain file name.
        let leaf = destination.lastPathComponent
        guard !leaf.isEmpty, leaf != ".", leaf != "..", !leaf.contains("/") else {
            return .failed("refusing unsafe file name \"\(leaf)\"")
        }
        // Only complete files are ever renamed into place, so presence alone proves it (the manifest
        // size can disagree slightly with the stored bytes, so it is not compared).
        if fm.fileExists(atPath: destination.path) { return .skipped(destination) }
        let part = destination.appendingPathExtension("part")
        do {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            return .failed("could not create the folder: \(error.localizedDescription)")
        }
        // A `.part` must be a plain file we made: never follow a symlink someone left in its place.
        if (try? fm.attributesOfItem(atPath: part.path)[.type] as? FileAttributeType) == .typeSymbolicLink {
            try? fm.removeItem(at: part)
        }
        if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: nil) }

        func partSize() -> Int { (try? fm.attributesOfItem(atPath: part.path)[.size] as? Int) ?? 0 }
        func finish() -> Result {
            // Nothing at the destination is ever deleted: if something appeared there meanwhile, keep
            // it and drop our copy.
            if fm.fileExists(atPath: destination.path) {
                try? fm.removeItem(at: part)
                return .skipped(destination)
            }
            do {
                try fm.moveItem(at: part, to: destination)
                return .saved(destination)
            } catch {
                return .failed("could not save: \(error.localizedDescription)")
            }
        }

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
            // Complete only when the bytes on disk match the size the server itself stated; the
            // manifest's size is a hint (it can be off, and wraps above 4 GiB), never proof.
            switch outcome {
            case .alreadyComplete:
                return finish()
            case .done(let total):
                if let total, after != total {
                    log("\(destination.lastPathComponent): have \(after) of \(total) bytes after a clean finish — resuming")
                } else {
                    return finish()
                }
            case .interrupted(let total?) where after == total:
                return finish()
            default:
                break
            }

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
            log(
                "\(what) at \(after / 1_000_000) MB — resuming \(destination.lastPathComponent) in \(Int(wait * 1000)) ms (attempt \(attempt + 1))"
            )
            try? await Task.sleep(for: .seconds(wait))
        }
    }

    /// One HTTP attempt, appending to `part` from `offset`.
    private func fetch(
        urlPath: String, into part: URL, from offset: Int,
        progress: @escaping @Sendable (Int) -> Void
    ) async -> Attempt {
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
                if early { state.done(.interrupted(total: nil)) } else { task.resume() }
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func state(_ task: URLSessionTask) -> TaskState? {
        lock.withLock { handlers[task.taskIdentifier] }
    }

    // ---- URLSessionDataDelegate (serial delegate queue) -------------------------------------------

    public func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let st = state(dataTask) else { completionHandler(.cancel); return }
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        let http = response as? HTTPURLResponse
        // A resume past the last byte: the server answers 416 with `bytes */TOTAL`.
        if code == 416, st.rangeStart > 0, Self.contentRangeTotal(http) == st.rangeStart {
            st.outcome = .alreadyComplete
            completionHandler(.cancel)
            return
        }
        if !(200...299).contains(code) {
            st.outcome = .failed(code)
            completionHandler(.cancel)
            return
        }
        // The camera serves files, never web pages: an HTML answer is some other device at this address.
        if let type = http?.value(forHTTPHeaderField: "Content-Type"), type.lowercased().contains("text/html") {
            st.outcome = .failed(-3)
            completionHandler(.cancel)
            return
        }
        if st.rangeStart > 0 && code != 206 {
            st.outcome = .rangeIgnored
            completionHandler(.cancel)
            return
        }
        st.total =
            code == 206
            ? Self.contentRangeTotal(http)
            : (response.expectedContentLength > 0 ? Int(response.expectedContentLength) : nil)
        completionHandler(.allow)
    }

    /// `Content-Range: bytes 100-199/1000` or `bytes */1000` → 1000.
    static func contentRangeTotal(_ response: HTTPURLResponse?) -> Int? {
        guard let value = response?.value(forHTTPHeaderField: "Content-Range"),
            let slash = value.lastIndex(of: "/")
        else { return nil }
        return Int(value[value.index(after: slash)...].trimmingCharacters(in: .whitespaces))
    }

    /// Never follow a redirect: the camera doesn't send them, and following one could fetch from any
    /// host. The 3xx then arrives as the response and counts as a refusal.
    public func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
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
        guard
            let st = lock.withLock({ () -> TaskState? in
                let st = handlers.removeValue(forKey: task.taskIdentifier)
                if st == nil { completedEarly.insert(task.taskIdentifier) }
                return st
            })
        else { return }
        st.progress(st.written)
        if let outcome = st.outcome {
            st.done(outcome)
        } else if let error {
            log("download error: \(error.localizedDescription)")
            st.done(.interrupted(total: st.total))
        } else {
            st.done(.done(total: st.total))
        }
    }
}
