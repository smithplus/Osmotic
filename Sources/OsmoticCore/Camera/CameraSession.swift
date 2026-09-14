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

    /// `.media`: playback held, listing and downloads (the proven path). `.capture`: out of playback,
    /// taking capture commands. `.live`: capture plus the live-view stream.
    private enum Mode { case media, capture, live }
    private var mode = Mode.media
    private var reassembler = LiveReassembler()
    private var videoSink: (@Sendable ([UInt8]) -> Void)?
    private var liveRequestedAt: Date?
    private var liveFallbackTried = false
    private var lastVideoAt: Date?
    private var lastAckAt = Date.distantPast
    private var lastBeatAt = Date.distantPast
    private var lastRxAt = Date()

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

    public init(
        ip: String = "192.168.2.1", model: CameraModel, interfaceName: String?,
        log: @escaping @Sendable (String) -> Void
    ) {
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
            guard !isClosed, mode == .media else { return ([], false) }
            let fresh = fetchNextPage()
            return (fresh, pagination.moreAvailable)
        }
    }

    // ---- camera control (see docs/CONTROL.md) ----------------------------------------------------

    /// Leave playback so the camera takes capture commands and can stream its live view.
    public func enterControl() async -> Bool {
        await submit { [self] in
            guard !isClosed else { return false }
            return controlEnter()
        }
    }

    /// Back to playback, then the newest page again (new clips may have been recorded meanwhile).
    public func leaveControl() async -> (files: [CameraFile], moreAvailable: Bool)? {
        await submit { [self] in
            guard !isClosed else { return nil }
            return controlLeave()
        }
    }

    public func setRecording(_ on: Bool) async -> Bool {
        await submit { [self] in !isClosed && controlRecord(on) }
    }

    public func takePhoto() async -> Bool {
        await submit { [self] in !isClosed && controlPhoto() }
    }

    public func setMode(_ mode: CaptureMode) async -> Bool {
        await submit { [self] in !isClosed && controlMode(mode) }
    }

    /// Start the H.264 live view; `onVideo` receives Annex-B access units on the worker thread.
    public func startLiveView(onVideo: @escaping @Sendable ([UInt8]) -> Void) async -> Bool {
        await submit { [self] in !isClosed && liveStart(onVideo) }
    }

    public func stopLiveView() async {
        await submit { [self] in liveStop() }
    }

    /// Release playback, close the socket and stop the session thread. A job already running aborts
    /// at its next receive; jobs queued behind it return empty.
    public func close() async {
        guard markClosed() else { return }  // already closed (or closing): never tear down twice
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

    /// True if this call closed the session, false if it already was.
    private func markClosed() -> Bool {
        cond.lock()
        defer { cond.unlock() }
        guard !closed else { return false }
        closed = true
        cond.signal()
        return true
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
                // Close the socket before anyone can see the worker gone, so a late `submit` running
                // inline can never close the same descriptor from another thread.
                tx.close()
                workerExited = true
                cond.unlock()
                break
            }
            let job = jobs.isEmpty ? nil : jobs.removeFirst()
            cond.unlock()
            if let job { job(); continue }
            if keepAliveOn && !stopRequested { keepAliveTick() }
        }
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
        log(
            "datalink: parsed \(files.count) media files (newest page; \(pagination.cursorDescription); more=\(pagination.moreAvailable))"
        )
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
            let ok = TCPProbe.connect(
                ip: ip, port: 7001, timeout: 1.2, payload: OsmoCommands.setPairingPin(),
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
            collect(into: &blob, recv(800))
            tx.sendAck()
            beat()
            if batch == 1 { send(0x00, 0x26, Pagination.trigger, rType: 0x01, rId: 0) }
            if batch == 2 { send(0x00, 0x26, intCmd, rType: 0x01, rId: 0) }
            let count = ManifestDecoder.countMediaPaths(ManifestDecoder.manifestBytes(blob))
            if count != lastCount { log("datalink: \(count) files (batch \(batch))") }
            progress(min(0.95, 0.55 + Double(batch) * 0.06))
            if batch >= 3 && ManifestDecoder.streamsEnded(blob, required: [Pagination.sdQueryCtr, Pagination.internalQueryCtr]) {
                break
            }
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
            collect(into: &blob, recv(700))
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
                prime: [
                    Pagination.trigger,
                    Pagination.listCommand(ctr: Pagination.internalQueryCtr, cursor: pagination.internalCursor),
                ],
                timeout: 12)
            let (page, slices) = ManifestDecoder.collectStores(blob, log: log)
            let truncated = slices.values.contains(where: \.incomplete)
            if !page.isEmpty && !truncated {
                let fresh = pagination.step(page: page, slices: slices)
                log(
                    "datalink: next page(inline) \(pagination.cursorDescription) +\(fresh.count) new (more=\(pagination.moreAvailable))"
                )
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
            collect(into: &blob, recv(800))
            tx.sendAck()
            beat()
            if batch == 1 { send(0x00, 0x26, Pagination.trigger, rType: 0x01, rId: 0) }
            if batch == 2 {
                send(
                    0x00, 0x26, Pagination.listCommand(ctr: Pagination.internalQueryCtr, cursor: pagination.internalCursor),
                    rType: 0x01, rId: 0)
            }
            let c = ManifestDecoder.countMediaPaths(ManifestDecoder.manifestBytes(blob))
            if batch >= 3 && ManifestDecoder.streamsEnded(blob, required: [Pagination.sdQueryCtr, Pagination.internalQueryCtr]) {
                break
            }
            if batch >= 4 && c > 0 && c == lastCount { stable += 1; if stable >= 2 { break } } else { stable = 0 }
            lastCount = c
        }
        let (page, slices) = ManifestDecoder.collectStores(blob, log: log)
        let fresh = pagination.step(page: page, slices: slices)
        log("datalink: next page \(pagination.cursorDescription) +\(fresh.count) new (more=\(pagination.moreAvailable))")
        startKeepAlive()
        return fresh
    }

    /// A real card's listing is a few hundred KB; past this, whatever is sending is not a camera
    /// listing its card, and the rest is dropped (the decoder rescans the blob every tick).
    static let maxManifestBytes = 8 << 20

    /// Keep only the manifest frames (`0x00/0x27`), each found by walking its own datagram. Joining
    /// whole datagrams let a stray `0x55` + lucky CRC in a status packet or a header read as a frame
    /// that swallowed the real chunks after it — a card listed short. The decoder itself is untouched.
    private func collect(into blob: inout [UInt8], _ datagrams: [[UInt8]]) {
        for d in datagrams {
            var frames: [UInt8] = []
            DumlScanner.walk(d) { f in
                if f.cmdSet == 0x00 && f.cmdId == 0x27 { frames += d[f.start..<(f.start + f.length)] }
            }
            guard !frames.isEmpty else { continue }
            guard blob.count + frames.count <= Self.maxManifestBytes else {
                log("datalink: manifest over \(Self.maxManifestBytes >> 20) MB — ignoring the rest")
                return
            }
            blob += frames
        }
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
            collect(into: &blob, recv(200))
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
        if mode != .media { controlTick(); return }
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
        videoSink = nil
        tx.onVideo = nil
        if keepAliveOn && playbackHeld && mode == .media && tx.isOpen {
            send(0x02, 0x0C, Self.playbackLeave, rType: 0x01, rId: 0)
            Thread.sleep(forTimeInterval: 0.15)  // let the leave land before the socket goes
            log("datalink: playback mode released")
        }
        keepAliveOn = false
        playbackHeld = false
        tx.close()
    }

    // ---- control implementation ------------------------------------------------------------------
    //
    // From Kaze for DJI (MIT, tested on a Pocket 3), OpenPocketCine (Apache-2.0, re-implemented from its
    // notes) and Osmosis' MEDIA_PROTOCOL; see docs/CONTROL.md. Everything below runs on the session
    // thread. Several steps are unverified on hardware and log what the camera answered.

    private static let liveStart = [UInt8](hex: "0100000000040000000501")  // 0x01/0x01, no reply
    private static let liveIdle = [UInt8](hex: "0000000000040000000401")
    private static let liveRequest = [UInt8](hex: "00040200000000000000")  // 0x09/0xA8 = keyframe + stream

    /// Receive a short burst, keep the windows acknowledged (≥ 40 Hz while anything flows) and the
    /// presence beat going. The pump every wait in capture mode goes through.
    private func pump() -> [[UInt8]] {
        let dg = tx.recvAll(ms: 12, precise: true)
        ingest(dg)
        let now = Date()
        if !dg.isEmpty { lastRxAt = now }
        if !dg.isEmpty || now.timeIntervalSince(lastAckAt) >= 0.025 {
            tx.sendAck()
            lastAckAt = now
        }
        if now.timeIntervalSince(lastBeatAt) >= 1 {
            beat()
            lastBeatAt = now
        }
        return dg
    }

    /// Pump until `done()` or `timeout`; true if `done()` became true.
    private func pumpUntil(_ timeout: TimeInterval, _ done: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isClosed { return false }
            _ = pump()
            if done() { return true }
        }
        return done()
    }

    /// Take in whatever is already waiting, so an earlier answer to the same command (the media
    /// keep-alive's refused playback re-asserts, say) can't be mistaken for the reply to the next one.
    private func drainStale() {
        _ = pumpUntil(0.06) { false }
    }

    /// Pump until the camera answers `set/cmd` (a non-empty reply; the empty transport ACK is skipped).
    /// Call `drainStale()` before sending the command.
    private func awaitReply(set: Int, cmd: Int, timeout: TimeInterval) -> [UInt8]? {
        var reply: [UInt8]?
        let deadline = Date().addingTimeInterval(timeout)
        while reply == nil && Date() < deadline && !isClosed {
            reply = DumlScanner.findReply(pump(), set: set, cmd: cmd)
        }
        return reply
    }

    /// The capture-mode keep-alive: a tight pump (jobs still start within ~12 ms), link watch by time,
    /// and the live-view fallback if no picture arrives.
    private func controlTick() {
        _ = pump()
        let now = Date()
        if now.timeIntervalSince(lastRxAt) > 8 {
            if !linkLostFired {
                linkLostFired = true
                log("datalink: camera silent for ~8 s in capture mode — link lost")
                onLinkLost?()
            }
        } else if linkLostFired {
            linkLostFired = false
            log("datalink: camera answering again — link restored")
            onLinkRestored?()
        }
        if mode == .live, lastVideoAt == nil, !liveFallbackTried,
            let asked = liveRequestedAt, now.timeIntervalSince(asked) > 8
        {
            // No picture from the Kaze request: try OpenPocketCine's once (0x02/0x68 [08], then 0x09/0xA8
            // to receiver 0x08). Never loop the request — each one resets the encoder's GOP.
            liveFallbackTried = true
            liveRequestedAt = now
            log("live: no video 8 s after the request — trying the alternate request (receiver 0x08)")
            send(0x02, 0x68, [0x08], rType: 0x01, rId: 0)
            send(0x09, 0xA8, Self.liveRequest, rType: 0x08, rId: 0)
        }
    }

    /// Kaze's live-view START burst: START/A8 interleaved, START ×5, IDLE ×4, 1-2 ms apart. Without
    /// `request` only the START/IDLE frames go out — enough to leave playback without starting a
    /// stream nobody is listening to yet (its one keyframe would be lost, and none follows).
    private func sendLiveStartBurst(request withRequest: Bool = true) {
        func start() { send(0x01, 0x01, Self.liveStart, rType: 0x01, rId: 0, cmdType: 0) }
        func request() { if withRequest { send(0x09, 0xA8, Self.liveRequest, rType: 0x01, rId: 2) } }
        start(); Thread.sleep(forTimeInterval: 0.001)
        request(); Thread.sleep(forTimeInterval: 0.001)
        start(); Thread.sleep(forTimeInterval: 0.001)
        request(); Thread.sleep(forTimeInterval: 0.001)
        for _ in 0..<5 { start(); Thread.sleep(forTimeInterval: 0.002) }
        for _ in 0..<4 { send(0x01, 0x01, Self.liveIdle, rType: 0x01, rId: 0, cmdType: 0); Thread.sleep(forTimeInterval: 0.002) }
    }

    private func controlEnter() -> Bool {
        if mode != .media { return true }
        log("control: leaving playback (txLag=\(tx.txLagSlots))")
        // Correct windows first: capture commands are answered on pktType 0x03, and those replies stop
        // unless we echo them. Stray video must never reach the status parser.
        tx.windowModel = .mimo
        tx.dropVideo = true
        playbackHeld = false  // stops the periodic playback re-assert
        lastRxAt = Date()
        mode = .capture
        let out = { self.tracker.playbackReported == false }
        if out() { log("control: camera already out of playback"); return true }
        // 1. The documented leave (OpenPocketCine), twice.
        for attempt in 1...2 {
            drainStale()
            send(0x02, 0x0C, Self.playbackLeave, rType: 0x01, rId: 0)
            if let reply = awaitReply(set: 0x02, cmd: 0x0C, timeout: 0.45) {
                log(String(format: "control: 0x02/0x0c leave → 0x%02x", reply[0]))
                if reply[0] == 0xE0 { break }
            }
            if pumpUntil(0.3, out) { log("control: out of playback (0x02/0x0c, attempt \(attempt))"); return true }
        }
        // 2. The Pocket 3's own route: its live-view START burst is the same 0x01/0x01 family that put it
        //    into playback.
        sendLiveStartBurst(request: false)
        if pumpUntil(1.5, out) { log("control: out of playback (0x01/0x01 START)"); return true }
        log("control: camera still reports playback — capture mode not reached")
        mode = .media
        tx.windowModel = .legacy
        return false
    }

    private func controlLeave() -> (files: [CameraFile], moreAvailable: Bool)? {
        if mode == .media { return nil }
        liveStop()
        log("control: back to playback for the card")
        mode = .media
        tx.windowModel = .legacy
        tx.sendAck()
        guard enterPlaybackConfirmed() else { return nil }
        let files = queryNewestPage()
        pagination.seed(with: files, slices: lastSlices)
        tick = 0
        return (files, pagination.moreAvailable)
    }

    /// Record start/stop (`0x02/0x02 [01|00]` — not a toggle). Confirmed by the recording bit of the
    /// `0x02/0x80` push; the Pocket 3 passes through a transition state (01→41→81, 81→C1→01).
    private func controlRecord(_ on: Bool) -> Bool {
        guard mode != .media else { return false }
        if tracker.status.recording == on && !tracker.status.recordingTransition { return true }
        drainStale()
        send(0x02, 0x02, [on ? 0x01 : 0x00], rType: 0x01, rId: 0)
        let reply = awaitReply(set: 0x02, cmd: 0x02, timeout: 1.0)
        if let reply { log(String(format: "control: record %@ → 0x%02x", on ? "start" : "stop", reply[0])) }
        if let reply, reply[0] != 0x00 { return false }
        let reached = pumpUntil(2.0) { self.tracker.status.recording == on && !self.tracker.status.recordingTransition }
        if !reached { log("control: recording state didn't reach \(on ? "on" : "off") within 2 s (txLag=\(tx.txLagSlots))") }
        return reached
    }

    /// One picture (`0x02/0x01 [01]`) — photo mode only (`D9` otherwise). Sent once, never repeated.
    private func controlPhoto() -> Bool {
        guard mode != .media else { return false }
        drainStale()
        send(0x02, 0x01, [0x01], rType: 0x01, rId: 0)
        guard let reply = awaitReply(set: 0x02, cmd: 0x01, timeout: 2.0) else {
            log("control: photo — no answer (txLag=\(tx.txLagSlots))")
            return false
        }
        log(String(format: "control: photo → 0x%02x", reply[0]))
        return reply[0] == 0x00
    }

    /// Capture mode (`0x02/0xE1 [code]`), only from the known table — never enumerate codes.
    private func controlMode(_ m: CaptureMode) -> Bool {
        guard mode != .media, !tracker.status.recording else { return false }
        drainStale()
        send(0x02, 0xE1, [m.rawValue], rType: 0x01, rId: 0)
        let reply = awaitReply(set: 0x02, cmd: 0xE1, timeout: 1.0)
        if let reply { log(String(format: "control: mode %@ → 0x%02x", String(describing: m), reply[0])) }
        if let reply, reply[0] != 0x00 { return false }
        return pumpUntil(1.5) { self.tracker.status.captureMode == m }
    }

    private func liveStart(_ onVideo: @escaping @Sendable ([UInt8]) -> Void) -> Bool {
        guard mode != .media || controlEnter() else { return false }
        videoSink = onVideo
        reassembler = LiveReassembler()
        lastVideoAt = nil
        liveFallbackTried = false
        tx.onVideo = { [unowned self] d in self.handleVideo(d) }
        sendLiveStartBurst()
        liveRequestedAt = Date()
        mode = .live
        log("live: requested (Kaze burst, receiver 0x41)")
        return true
    }

    private func handleVideo(_ d: [UInt8]) {
        guard let message = reassembler.feed(d, now: Date().timeIntervalSinceReferenceDate) else { return }
        if lastVideoAt == nil, let asked = liveRequestedAt {
            log("live: first picture data \(Int(Date().timeIntervalSince(asked) * 1000)) ms after the request")
        }
        lastVideoAt = Date()
        videoSink?(message)
    }

    /// There is no stop command: stop decoding and keep acknowledging whatever still arrives.
    private func liveStop() {
        guard mode == .live else { return }
        videoSink = nil
        tx.onVideo = nil
        tx.dropVideo = true
        mode = .capture
        log("live: stopped (dropped \(reassembler.dropped), invalid \(reassembler.invalid))")
    }

}
