import Foundation

/// A media session with an Osmo camera over the UDP datalink: registration, playback mode, the
/// CompositePack media list with per-store pagination, and the keep-alive that holds the camera's AP
/// and playback mode up while the app browses and downloads.
///
/// **Threading.** One dedicated thread owns the socket. Every protocol step runs on it — public async
/// methods enqueue a job and await its result — so sequence numbers can never interleave (the reason
/// the Android original needed its keep-alive thread to send everything). Between jobs the thread runs
/// keep-alive ticks.
public final class CameraSession: @unchecked Sendable {
    public struct ConnectResult: Sendable {
        public let handshakeOk: Bool
        public let files: [CameraFile]
        public let moreAvailable: Bool
        public let model: CameraModel
    }

    public let ip: String
    public private(set) var model: CameraModel
    private let interfaceName: String?
    private let log: @Sendable (String) -> Void

    /// Called on the session thread; hop to the main actor yourself.
    public var onStatus: (@Sendable (CameraStatus) -> Void)?
    public var onProgress: (@Sendable (Double) -> Void)?
    /// The camera stopped sending anything (AP gone, camera off). Fired once per outage.
    public var onLinkLost: (@Sendable () -> Void)?
    /// Packets are arriving again after `onLinkLost`.
    public var onLinkRestored: (@Sendable () -> Void)?

    // ---- worker-thread state (touch only on the session thread) --------------------------------
    private var tx: DatalinkTransport
    private var tracker = StatusTracker()
    private var pagination = Pagination()
    private var keepAliveOn = false
    private var playbackHeld = false
    private var tick = 0
    private var silentTicks = 0
    private var linkLostFired = false

    // ---- job queue ------------------------------------------------------------------------------
    private let cond = NSCondition()
    private var jobs: [@Sendable () -> Void] = []
    private var stopRequested = false
    private var thread: Thread?

    /// Status keys to subscribe to (`0x00/0x99`) — deliberately few; more would flood the manifest stream.
    private static let paramSubs = [
        "camcap_mode_profile", "camcap_video_format", "camcap_fov", "camcap_iso",
        "camcap_photo_storage_format", "camcap_color_mode", "cam_storage", "cam_status",
    ]

    /// `0x00/0x88` sub-command `0x17` — the ~1 Hz app-presence beat that keeps playback held.
    private static let appPresence = [UInt8](hex: "170046237c415050000000000002")
    private static let playbackEnter = [UInt8](hex: "01010001")
    private static let playbackLeave = [UInt8](hex: "01010000")
    private static let streamQuiet: TimeInterval = 2.5

    public init(ip: String = "192.168.2.1", model: CameraModel, interfaceName: String?,
                log: @escaping @Sendable (String) -> Void) {
        self.ip = ip
        self.model = model
        self.interfaceName = interfaceName
        self.log = log
        self.tx = DatalinkTransport(port: model.datalinkPort, interfaceName: interfaceName, log: log)
        tx.shouldAbort = { [unowned self] in self.isClosed }
        // Strong capture on purpose: the thread keeps the session alive until `close()` ends it.
        let t = Thread { self.run() }
        t.name = "osmotic-datalink"
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
    }

    // ---- public API -----------------------------------------------------------------------------

    /// Bring the datalink up (trying the model's port, then the alternate), register, enter playback
    /// and fetch the newest page. On success the keep-alive starts.
    public func connect() async -> ConnectResult {
        await submit { [self] in
            guard !isClosed else { return ConnectResult(handshakeOk: false, files: [], moreAvailable: false, model: model) }
            var result = connectOnce(model: model)
            if !result.handshakeOk && !isClosed {
                let alt = model.alternate()
                log("datalink: nothing answered on udp/\(model.datalinkPort) — trying udp/\(alt.datalinkPort)")
                result = connectOnce(model: alt)
                if result.handshakeOk { model = alt }
            }
            if result.handshakeOk && !isClosed { startKeepAlive() }
            return isClosed ? ConnectResult(handshakeOk: false, files: [], moreAvailable: false, model: model) : result
        }
    }

    /// The next older page (only newly seen files), or empty when the library is exhausted.
    public func nextPage() async -> (files: [CameraFile], moreAvailable: Bool) {
        await submit { [self] in
            guard !isClosed else { return ([], false) }
            let fresh = fetchNextPage()
            return (fresh, pagination.moreAvailable)
        }
    }

    /// Release playback, close the socket and stop the session thread. A job already running aborts
    /// at its next receive; jobs queued behind it return empty.
    public func close() async {
        markClosed()
        await submit { [self] in
            teardown()
        }
        requestStop()
    }

    private var closed = false

    /// Thread-safe: read from the worker's loops, set by `close()` from any thread.
    public var isClosed: Bool {
        cond.lock()
        defer { cond.unlock() }
        return closed
    }

    private func markClosed() {
        cond.lock()
        closed = true
        cond.signal()
        cond.unlock()
    }

    private func requestStop() {
        cond.lock()
        stopRequested = true
        cond.signal()
        cond.unlock()
    }

    // ---- worker loop ----------------------------------------------------------------------------

    private func submit<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
            cond.lock()
            if workerExited {
                cond.unlock()
                // The thread is gone and the socket closed; nothing can race this any more, and the
                // caller must never be left hanging.
                cont.resume(returning: body())
                return
            }
            jobs.append { cont.resume(returning: body()) }
            cond.signal()
            cond.unlock()
        }
    }

    private var workerExited = false

    private func run() {
        while true {
            cond.lock()
            while jobs.isEmpty && !stopRequested && !keepAliveOn { cond.wait() }
            if stopRequested && jobs.isEmpty {
                workerExited = true
                cond.unlock()
                break
            }
            let job = jobs.isEmpty ? nil : jobs.removeFirst()
            cond.unlock()
            if let job { job(); continue }
            if keepAliveOn && !stopRequested { keepAliveTick() }
        }
        tx.close()
    }

    /// Sleep up to `seconds`, returning early when a job arrives.
    private func pause(_ seconds: TimeInterval) {
        cond.lock()
        if jobs.isEmpty && !stopRequested { _ = cond.wait(until: Date().addingTimeInterval(seconds)) }
        cond.unlock()
    }

    // ---- transport helpers ----------------------------------------------------------------------

    private func send(_ set: Int, _ cmd: Int, _ payload: [UInt8], rType: Int, rId: Int, cmdType: Int = 2) {
        tx.sendDuml(set: set, cmd: cmd, payload: payload, receiverType: rType, receiverId: rId, cmdType: cmdType)
    }

    private func recv(_ ms: Int) -> [[UInt8]] {
        let dg = tx.recvAll(ms: ms)
        ingest(dg)
        return dg
    }

    private func ingest(_ dg: [[UInt8]]) {
        if tracker.ingest(dg, log: log) { onStatus?(tracker.status) }
    }

    private func beat() { send(0x00, 0x88, Self.appPresence, rType: 0x08, rId: 1) }

    private func progress(_ p: Double) { onProgress?(p) }

    // ---- connect --------------------------------------------------------------------------------

    private func connectOnce(model m: CameraModel) -> ConnectResult {
        log("=== media list [\(m.name)] via udp/\(m.datalinkPort) (poke=\(m.tcpPoke)) ===")
        tx.close()
        tx = DatalinkTransport(port: m.datalinkPort, interfaceName: interfaceName, log: log)
        tx.shouldAbort = { [unowned self] in self.isClosed }
        guard openAndRegister(model: m, subscribe: true) else {
            return ConnectResult(handshakeOk: false, files: [], moreAvailable: false, model: m)
        }
        syncTime()
        progress(0.5)
        enterPlaybackConfirmed()
        var files = queryNewestPage()
        if files.isEmpty && lastRawWasSilent {
            // A camera can hold a session from a previous connection: handshake fine, media query never
            // answered. A fresh base sequence is what clears it.
            log("datalink: the list query got no reply frames at all — re-registering once")
            if openAndRegister(model: m, subscribe: false) {
                enterPlaybackConfirmed()
                files = queryNewestPage()
            }
        }
        pagination.seed(with: files, slices: lastSlices)
        log("datalink: parsed \(files.count) media files (newest page; \(pagination.cursorDescription); more=\(pagination.moreAvailable))")
        progress(1.0)
        return ConnectResult(handshakeOk: true, files: files, moreAvailable: pagination.moreAvailable, model: m)
    }

    private func openDatalink(model m: CameraModel) -> Bool {
        do {
            try tx.open(ip: ip)
        } catch {
            log("datalink: \(error)")
            return false
        }
        if m.tcpPoke {
            let ok = TCPProbe.connect(ip: ip, port: 7001, timeout: 1.2, payload: OsmoCommands.setPairingPin(),
                                      hold: 0.4, interfaceName: interfaceName)
            log("datalink: tcp/7001 poke \(ok ? "sent" : "not accepted")")
        }
        guard tx.handshake() != nil else {
            log("datalink: handshake FAILED on udp/\(m.datalinkPort)")
            tx.close()
            return false
        }
        log("datalink: handshake OK on udp/\(m.datalinkPort)")
        progress(0.08)
        tracker.reset()
        for _ in 0..<5 {
            _ = recv(400)
            tx.sendAck()
        }
        tx.syncSeqToPeerChannel()
        progress(0.16)
        log(String(format: "datalink: session=0x%04x base=0x%04x channel=0x%04x", tx.sessionId, tx.baseSeq, tx.cameraChannel))
        if tx.cameraChannel != tx.baseSeq {
            log("datalink: peer answered on its own sequence channel — it may be holding a previous session")
        }
        silentTicks = 0
        linkLostFired = false
        return true
    }

    private func openAndRegister(model m: CameraModel, subscribe: Bool) -> Bool {
        guard openDatalink(model: m) else { return false }
        send(0x00, 0x81, OsmoCommands.appDeviceInfo, rType: 0x08, rId: 2, cmdType: 4)
        _ = recv(400); tx.sendAck()
        send(0x00, 0x88, Self.appPresence, rType: 0x08, rId: 1)
        _ = recv(400); tx.sendAck()
        send(0x03, 0xDA, [UInt8](hex: "05ffffffff"), rType: 0x03, rId: 0)
        _ = recv(400); tx.sendAck()
        if subscribe {
            var subId = 0x69DF
            for (i, name) in Self.paramSubs.enumerated() {
                send(0x00, 0x99, Self.subscription(name, subId: subId), rType: 0x08, rId: 1)
                subId += 1
                if i % 8 == 7 { _ = recv(20); tx.sendAck() }
                progress(0.22 + Double(i) * 0.2 / Double(Self.paramSubs.count))
            }
            for _ in 0..<4 { _ = recv(400); tx.sendAck() }
        }
        return true
    }

    /// `[02 02 00 00][subId u32][00 00 00][nameLen+6 u16][nameLen u16][name][00 00 00 00]`.
    static func subscription(_ name: String, subId: Int) -> [UInt8] {
        let n = Array(name.utf8)
        return [0x02, 0x02, 0x00, 0x00] + LE.u32(subId) + [0, 0, 0] + LE.u16(n.count + 6) + LE.u16(n.count) + n + [0, 0, 0, 0]
    }

    /// Set the camera clock + timezone to the Mac's (`0x00/0x6a` to the RTC receiver `0x28`).
    private func syncTime() {
        let now = Int(Date().timeIntervalSince1970)
        let tz = TimeZone.current
        let offMin = tz.secondsFromGMT() / 60
        let tzId = Array(tz.identifier.utf8)
        let payload: [UInt8] = [0x01, 0x00] + LE.u64(now) + LE.u16(offMin & 0xFFFF) + [UInt8(tzId.count & 0xFF)] + tzId
        send(0x00, 0x6A, payload, rType: 0x08, rId: 1)
        _ = recv(300); tx.sendAck()
        log("datalink: time synced (UTC offset \(offMin) min, \(tz.identifier))")
    }

    // ---- playback mode --------------------------------------------------------------------------

    /// Put the camera into playback and wait for bit 30 of `0x02/0x80` to say so. A Pocket 3 refuses
    /// `0x02/0x0c` (`e0`), so a refusal switches to its `0x01/0x01` route at once.
    @discardableResult
    private func enterPlaybackConfirmed(attempts: Int = 3) -> Bool {
        _ = recv(120)
        if tracker.playbackReported == true {
            playbackHeld = true
            log("datalink: playback mode already held (camera says so)")
            return true
        }
        for n in 0..<attempts {
            send(0x02, 0x0C, Self.playbackEnter, rType: 0x01, rId: 0)
            let deadline = Date().addingTimeInterval(0.9)
            while Date() < deadline {
                let dg = recv(100)
                if tracker.playbackReported == true {
                    playbackHeld = true
                    log("datalink: playback mode held" + (n > 0 ? " (confirmed on attempt \(n + 1))" : ""))
                    return true
                }
                if let reply = DumlScanner.findReply(dg, set: 0x02, cmd: 0x0C), reply[0] != 0x00 {
                    log(String(format: "datalink: playback refused (0x%02x) — trying 0x01/0x01", reply[0]))
                    return enterPlaybackViaControl()
                }
                tx.sendAck()
            }
        }
        if enterPlaybackViaControl() { return true }
        log("datalink: playback mode NOT confirmed after \(attempts) attempts — camera may still be in capture")
        return false
    }

    /// The Pocket 3's playback entry, replayed from a capture of the official app: six frames of the
    /// prelude, then the enter frame at ~20 Hz until the playback bit sets. No reply exists.
    private func enterPlaybackViaControl() -> Bool {
        log("datalink: trying 0x01/0x01 playback entry (the Pocket 3 route)")
        let prelude = [UInt8](hex: "0300000000040000000701")
        let enter = [UInt8](hex: "0000000000040000000401")
        let deadline = Date().addingTimeInterval(2.5)
        var sent = 0
        var silent = 0
        while Date() < deadline {
            send(0x01, 0x01, sent < 6 ? prelude : enter, rType: 0x01, rId: 0, cmdType: 0)
            sent += 1
            let got = recv(50)
            if tracker.playbackReported == true {
                playbackHeld = true
                log("datalink: playback mode held via 0x01/0x01 (after \(sent) frames)")
                return true
            }
            silent = got.isEmpty ? silent + 1 : 0
            if silent >= 8 {
                log("datalink: 0x01/0x01 — camera stopped answering after \(sent) frames, aborting")
                return false
            }
        }
        log("datalink: 0x01/0x01 sent \(sent) frames, camera still reports capture")
        return false
    }

    // ---- listing --------------------------------------------------------------------------------

    private var lastSlices: [Int: SliceInfo] = [:]
    private var lastRawWasSilent = false

    /// The newest page from both stores: query SD → trigger → query internal, collect until the camera
    /// closes both answers or the path count settles.
    private func queryNewestPage() -> [CameraFile] {
        let sdCmd = Pagination.listCommand(ctr: Pagination.sdQueryCtr, cursor: Pagination.newestSd)
        let intCmd = Pagination.listCommand(ctr: Pagination.internalQueryCtr, cursor: Pagination.newestInternal)
        send(0x00, 0x26, sdCmd, rType: 0x01, rId: 0)
        var blob: [UInt8] = []
        var lastCount = -1
        var stable = 0
        for batch in 0..<15 {
            for r in recv(800) { blob += r }
            tx.sendAck()
            beat()
            if batch == 1 { send(0x00, 0x26, Pagination.trigger, rType: 0x01, rId: 0) }
            if batch == 2 { send(0x00, 0x26, intCmd, rType: 0x01, rId: 0) }
            let count = ManifestDecoder.countMediaPaths(ManifestDecoder.manifestBytes(blob))
            if count != lastCount { log("datalink: \(count) files (batch \(batch))") }
            progress(min(0.95, 0.55 + Double(batch) * 0.06))
            if batch >= 3 && ManifestDecoder.streamsEnded(blob, required: [Pagination.sdQueryCtr, Pagination.internalQueryCtr]) { break }
            if batch >= 4 && count > 0 && count == lastCount { stable += 1; if stable >= 2 { break } } else { stable = 0 }
            lastCount = count
        }
        blob = retrySdIfNotReady(blob)
        lastRawWasSilent = ManifestDecoder.chunkTally(blob).isEmpty
        let (files, slices) = ManifestDecoder.collectStores(blob, log: log)
        lastSlices = slices
        return files
    }

    /// A store is not always mounted the instant playback is confirmed; re-ask an empty SD answer once.
    private func retrySdIfNotReady(_ first: [UInt8]) -> [UInt8] {
        if !ManifestDecoder.manifestBytes(first, requestCtr: Pagination.sdQueryCtr).isEmpty { return first }
        log("datalink: SD store answered empty — re-asking once (it may not have been mounted yet)")
        var blob = first
        send(0x00, 0x26, Pagination.listCommand(ctr: Pagination.sdQueryCtr, cursor: Pagination.newestSd), rType: 0x01, rId: 0)
        for batch in 0..<6 {
            for r in recv(700) { blob += r }
            tx.sendAck()
            beat()
            if batch == 1 { send(0x00, 0x26, Pagination.trigger, rType: 0x01, rId: 0) }
            if batch >= 2 && ManifestDecoder.streamsEnded(blob, required: [Pagination.sdQueryCtr]) { break }
        }
        let n = ManifestDecoder.countMediaPaths(ManifestDecoder.manifestBytes(blob, requestCtr: Pagination.sdQueryCtr))
        log("datalink: SD retry -> \(n) record(s)")
        return blob
    }

    private func fetchNextPage() -> [CameraFile] {
        guard pagination.moreAvailable else { return [] }
        if keepAliveOn && tx.isOpen {
            let blob = runManifestQuery(
                Pagination.listCommand(ctr: Pagination.sdQueryCtr, cursor: pagination.sdCursor),
                prime: [Pagination.trigger,
                        Pagination.listCommand(ctr: Pagination.internalQueryCtr, cursor: pagination.internalCursor)],
                timeout: 12)
            let (page, slices) = ManifestDecoder.collectStores(blob, log: log)
            let truncated = slices.values.contains(where: \.incomplete)
            if !page.isEmpty && !truncated {
                let fresh = pagination.step(page: page, slices: slices)
                log("datalink: next page(inline) \(pagination.cursorDescription) +\(fresh.count) new (more=\(pagination.moreAvailable))")
                return fresh
            }
            log("datalink: next page(inline) \(truncated ? "TRUNCATED" : "empty") — fresh-session fallback")
        }
        // Fresh registered session, then resume the keep-alive.
        keepAliveOn = false
        tx.close()
        guard openAndRegister(model: model, subscribe: false) else {
            log("datalink: next-page open FAILED — the session is gone")
            pagination.moreAvailable = false
            if !linkLostFired && !isClosed {
                linkLostFired = true
                onLinkLost?()
            }
            return []
        }
        enterPlaybackConfirmed()
        var blob: [UInt8] = []
        send(0x00, 0x26, Pagination.listCommand(ctr: Pagination.sdQueryCtr, cursor: pagination.sdCursor), rType: 0x01, rId: 0)
        var lastCount = -1
        var stable = 0
        for batch in 0..<12 {
            for r in recv(800) { blob += r }
            tx.sendAck()
            beat()
            if batch == 1 { send(0x00, 0x26, Pagination.trigger, rType: 0x01, rId: 0) }
            if batch == 2 {
                send(0x00, 0x26, Pagination.listCommand(ctr: Pagination.internalQueryCtr, cursor: pagination.internalCursor),
                     rType: 0x01, rId: 0)
            }
            let c = ManifestDecoder.countMediaPaths(ManifestDecoder.manifestBytes(blob))
            if batch >= 3 && ManifestDecoder.streamsEnded(blob, required: [Pagination.sdQueryCtr, Pagination.internalQueryCtr]) { break }
            if batch >= 4 && c > 0 && c == lastCount { stable += 1; if stable >= 2 { break } } else { stable = 0 }
            lastCount = c
        }
        let (page, slices) = ManifestDecoder.collectStores(blob, log: log)
        let fresh = pagination.step(page: page, slices: slices)
        log("datalink: next page \(pagination.cursorDescription) +\(fresh.count) new (more=\(pagination.moreAvailable))")
        startKeepAlive()
        return fresh
    }

    /// A manifest-stream query on the live session: send the query, then each prime frame one tick
    /// apart, and collect until the camera closes every answer, the count sits still, or the deadline.
    private func runManifestQuery(_ payload: [UInt8], prime: [[UInt8]], timeout: TimeInterval) -> [UInt8] {
        send(0x00, 0x26, payload, rType: 0x01, rId: 0)
        var blob: [UInt8] = []
        var ticks = 0, lastCount = -1
        var lastChange = Date()
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if isClosed { return blob }
            for r in recv(200) { blob += r }
            ticks += 1
            if ticks <= prime.count { send(0x00, 0x26, prime[ticks - 1], rType: 0x01, rId: 0) }
            let cnt = ManifestDecoder.countMediaPaths(ManifestDecoder.manifestBytes(blob))
            let allSent = ticks >= prime.count + 1
            if allSent && cnt > 0 && ManifestDecoder.streamsEnded(blob) { return blob }
            if cnt != lastCount { lastChange = Date() }
            // Quiet for as long as Osmosis' 5 × 500 ms ticks: a shorter window cut pages mid-stream.
            if allSent && cnt > 0 && Date().timeIntervalSince(lastChange) >= Self.streamQuiet { return blob }
            lastCount = cnt
            if Date() > deadline {
                log("datalink: manifest stream deadline after \(ticks) ticks, \(cnt) paths — reply may be truncated")
                return blob
            }
            tx.sendAck()
            if tick % 3 == 0 { beat() }
            tick += 1
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    // ---- keep-alive -----------------------------------------------------------------------------

    private func startKeepAlive() {
        guard tx.isOpen else { return }
        keepAliveOn = true
        tick = 0
        enterPlaybackConfirmed()
    }

    /// One ~0.5 s tick: drain + decode status, ACK the peer's windows, beat at ~1 Hz, re-assert
    /// playback every ~15 s. Polls the camera for nothing — status arrives unprompted.
    private func keepAliveTick() {
        let dg = recv(200)
        if dg.isEmpty {
            silentTicks += 1
            if silentTicks >= 16 && !linkLostFired {
                linkLostFired = true
                log("datalink: camera silent for ~8 s — link lost")
                onLinkLost?()
            }
        } else {
            silentTicks = 0
            if linkLostFired {
                linkLostFired = false
                log("datalink: camera answering again — link restored")
                onLinkRestored?()
            }
        }
        tx.sendAck()
        if tick % 3 == 0 { beat() }
        if playbackHeld && tick % 33 == 0 { send(0x02, 0x0C, Self.playbackEnter, rType: 0x01, rId: 0) }
        tick += 1
        pause(0.3)
    }

    private func teardown() {
        if keepAliveOn && playbackHeld && tx.isOpen {
            send(0x02, 0x0C, Self.playbackLeave, rType: 0x01, rId: 0)
            Thread.sleep(forTimeInterval: 0.15)   // let the leave land before the socket goes
            log("datalink: playback mode released")
        }
        keepAliveOn = false
        playbackHeld = false
        tx.close()
    }
}
