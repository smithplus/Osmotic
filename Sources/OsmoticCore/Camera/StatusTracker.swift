import Foundation

/// Accumulates the status pushes a registered camera sends unprompted: `0x02/0x80` state flags +
/// active store, `0x02/0xdc` per-store capacity, `0x0d/0x02` battery, `0x00/0x00` version.
public struct StatusTracker: Sendable {
    public private(set) var status = CameraStatus()
    /// Bit 30 of the `0x02/0x80` flags word — the camera's own word on whether it is in playback.
    public private(set) var playbackReported: Bool?
    private var lastSignature = ""
    private var lastStorageSig = ""
    private var lastBatterySig = ""

    public init() {}

    public mutating func reset() { self = StatusTracker() }

    /// Scan datagrams for status frames and apply them. Returns true when anything the UI shows changed.
    public mutating func ingest(_ datagrams: [[UInt8]], log: (String) -> Void) -> Bool {
        for d in datagrams {
            DumlScanner.walk(d) { f in apply(set: f.cmdSet, id: f.cmdId, payload: f.payload, log: log) }
        }
        let sig = displaySignature
        if sig != lastSignature { lastSignature = sig; return true }
        return false
    }

    private var displaySignature: String {
        let s = status
        return "\(s.batteryPercent)|\(s.sdTotalMb / 1024)|\(s.sdFreeMb / 1024)|\(s.internalFreeMb / 1024)"
            + "|\(s.storageFreeMb / 1024)|\(s.storageTotalMb / 1024)|\(s.docked)|\(s.charging)"
            + "|\(s.recording)|\(s.recordingTransition)|\(s.recordingSeconds)|\(s.captureMode?.rawValue ?? 0xFF)"
    }

    @discardableResult
    public mutating func apply(set: Int, id: Int, payload p: [UInt8], log: (String) -> Void) -> Bool {
        func sane(_ v: Int) -> Bool { (0...50_000_000).contains(v) }
        switch (set, id) {
        case (0x02, 0x80) where p.count >= 13:
            let inPlayback = (p.u32le(0) & 0x4000_0000) != 0
            if playbackReported != inPlayback {
                playbackReported = inPlayback
                log("camera reports playback mode: \(inPlayback ? "YES" : "no")")
            }
            let total = p.u32le(5), free = p.u32le(9)
            if (1...50_000_000).contains(total) { status.storageTotalMb = total }
            if sane(free) { status.storageFreeMb = free }
            // Capture state (Kaze for DJI, MIT, Pocket3CameraDomain; Osmosis MEDIA_PROTOCOL): byte 0
            // bit 7 = recording, bit 6 = between states (01 → 41 → 81 on start, 81 → C1 → 01 on stop).
            let wasRecording = status.recording
            status.recording = p[0] & 0x80 != 0
            status.recordingTransition = p[0] & 0x40 != 0
            if p.count >= 58 {
                let clipMode = p[4] == 1
                status.recordingSeconds = clipMode && status.recording ? p.u16le(29) : 0
                if let mode = CaptureMode(rawValue: p[57]), mode != status.captureMode {
                    status.captureMode = mode
                    log("camera mode: \(mode)")
                }
            }
            if wasRecording != status.recording { log("camera recording: \(status.recording ? "YES" : "no")") }
            return true
        case (0x02, 0xDC) where p.count >= 22:
            let sdTotal = p.u32le(6), sdFree = p.u32le(10)
            let hasInternal = p.count >= 32
            let inTotal = hasInternal ? p.u32le(24) : 0
            let inFree = hasInternal ? p.u32le(28) : 0
            // Free space ticks down every push while recording: log it once per GB, not every 400 ms.
            let sig = "\(p.count)|\(sdTotal)|\(sdFree / 1000)|\(inTotal)|\(inFree / 1000)"
            if sig != lastStorageSig {
                lastStorageSig = sig
                log(
                    "storage: 0x02/0xdc \(p.count)B stores=\(p[2]) first=\(sdTotal)/\(sdFree) MB"
                        + (hasInternal ? " built-in=\(inTotal)/\(inFree) MB" : " (no built-in block)"))
            }
            // A Nano pushes a zeroed first block while playback is held; keep the last real figures.
            let blanked = sdTotal == 0 && status.sdTotalMb > 0
            if sane(sdTotal) && !blanked { status.sdTotalMb = sdTotal }
            if sane(sdFree) && !blanked { status.sdFreeMb = sdFree }
            if !hasInternal {
                status.internalTotalMb = 0
                status.internalFreeMb = 0
            } else {
                if sane(inTotal) { status.internalTotalMb = inTotal }
                if sane(inFree) { status.internalFreeMb = inFree }
            }
            return true
        case (0x04, 0x05):
            return true
        case (0x00, 0x00) where p.count >= 6:
            let text = String(decoding: p, as: UTF8.self)
            if let m = text.firstMatch(of: /\d{2}\.\d{2}\.\d{2}\.\d{2}/) {
                status.firmware = String(m.output)
                return true
            }
        case (0x0D, 0x02) where p.count >= 21:
            if p.count >= 34 {
                let mv = p.u16le(1)
                let cur = p.i32le(5)
                let docked = p[27] != 0
                let charging = p[32] == 1
                if (2000...5000).contains(mv) { status.batteryMilliVolts = mv }
                status.batteryMilliAmps = cur
                status.docked = docked
                status.charging = charging
                let sig = "\(docked)|\(charging)|\(cur == 0 ? "0" : cur < 0 ? "-" : "+")"
                if sig != lastBatterySig {
                    lastBatterySig = sig
                    log("battery: \(p[20])% \(mv)mV \(cur)mA docked=\(docked) charging=\(charging)")
                }
            }
            let bp = Int(p[20])
            if (0...100).contains(bp) { status.batteryPercent = bp; return true }
            if p.count >= 34 { return true }
        default:
            break
        }
        return false
    }
}
