// The landing's videos, rendered frame by frame by the app itself in demo mode and stitched into
// loops with ffmpeg. No screen recording is involved: every picture is the app drawing its own
// window (snapshot.sh), with synthetic footage (make_scenes.swift). Only the pointer and its click
// rings are added here.
//
//   scripts/package_app.sh && swift scripts/make_demo_video.swift . [hero|live]   (default: both)
//   hero → docs/images/demo.mp4 + demo-poster.webp: one session (connect, tick two clips, download)
//   live → docs/images/live.mp4 + live-poster.webp: record, stop, switch modes
// H.264, 1400×966, 30 fps, no audio. Each loop starts on its most telling frame, which is also its
// poster. The step times printed at the end go in the page's data-steps. Needs ffmpeg and cwebp.
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let wanted = CommandLine.arguments.count > 2 ? [CommandLine.arguments[2]] : ["hero", "live"]
let work = root.appendingPathComponent("build/video")
let raw = work.appendingPathComponent("raw")
let scenes = work.appendingPathComponent("scenes")
let images = root.appendingPathComponent("docs/images")
let fixture = root.appendingPathComponent("Tests/OsmoticCoreTests/Fixtures/op3_15.bin").path
try? FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)

// Output geometry: the window (1120×740 pt of content plus the 32-pt title band) at 1.25 px per
// point, with one row of plate at the bottom so both sides are even, as H.264 wants.
let fps = 30.0
let s: CGFloat = 1.25
let W = 1400, H = 966
let bodyH = 925

@discardableResult
func run(_ exe: String, _ args: [String], env: [String: String] = [:], stdin: Pipe? = nil, wait: Bool = true) throws -> Process {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    if let stdin { p.standardInput = stdin }
    try p.run()
    if wait { p.waitUntilExit() }
    return p
}

if !FileManager.default.fileExists(atPath: scenes.appendingPathComponent("00-sunset-sea.jpg").path) {
    try run("/usr/bin/env", ["swift", root.appendingPathComponent("scripts/make_scenes.swift").path, scenes.path])
}

/// Renders one demo state to raw/<name>.png unless it's already there.
func shot(_ name: String, _ screen: String, _ env: [String: String] = [:]) throws {
    let out = raw.appendingPathComponent("\(name).png")
    if FileManager.default.fileExists(atPath: out.path) { return }
    try run(
        "/bin/bash", [root.appendingPathComponent("scripts/snapshot.sh").path, out.path, screen, fixture],
        env: env.merging([
            "OSMOTIC_LANG": "en", "OSMOTIC_LOCALE": "en_US", "OSMOTIC_DEMO_THUMBS": scenes.path,
            "OSMOTIC_SNAPSHOT_DELAY": "1.5",
        ]) { $1 })
    guard FileManager.default.fileExists(atPath: out.path) else { fatalError("no render for \(name)") }
    print("rendered \(name)")
}

// ---- Storyboards ---------------------------------------------------------------------------------

struct Step {
    let image: String
    let start: Double
    let seconds: Double
}
struct Key {
    let t: Double
    let at: CGPoint  // points, from the top left of the window's content
    var click = false
}
/// Built up step by step: `hold` returns when its step starts, for placing the pointer's keys.
final class Board {
    var steps: [Step] = []
    var keys: [Key] = []
    var chapters: [(Double, String)] = []
    var total = 0.0
    @discardableResult
    func hold(_ image: String, _ seconds: Double) -> Double {
        steps.append(Step(image: image, start: total, seconds: seconds))
        total += seconds
        return total - seconds
    }
    func move(_ t: Double, _ p: CGPoint) { keys.append(Key(t: t, at: p)) }
    func click(_ t: Double, _ p: CGPoint) { keys.append(Key(t: t, at: p, click: true)) }
    func chapter(_ name: String) { chapters.append((total, name)) }
}

func progressName(_ f: Double) -> String { String(format: "p-%03d", Int((f * 100).rounded())) }

/// Connect, tick two clips, download them. Starts mid-download: the frame people know from the README.
func hero() throws -> Board {
    let early = [0.04, 0.1, 0.17, 0.24]  // right after the click, before the loop wraps
    let late = [0.31, 0.39, 0.47, 0.55, 0.63, 0.71, 0.8, 0.9, 1.0]  // where the loop starts
    try shot("cameras", "cameras")
    for stage in ["bluetooth", "pairing", "wifi", "datalink"] {
        try shot("c-\(stage)", "connecting", ["OSMOTIC_DEMO_STAGE": stage])
    }
    for n in 0...2 { try shot("lib-\(n)", "library", ["OSMOTIC_DEMO_SELECT": "\(n)", "OSMOTIC_DEMO_PROGRESS": "none"]) }
    for f in early + late {
        try shot(progressName(f), "library", ["OSMOTIC_DEMO_SELECT": "2", "OSMOTIC_DEMO_PROGRESS": "\(f)"])
    }
    try shot("done", "library", ["OSMOTIC_DEMO_SELECT": "2", "OSMOTIC_DEMO_DONE": "1"])

    // Where things are on the 1120×740 window (from the renders).
    let downloadKey = CGPoint(x: 1018, y: 139)
    let connectKey = CGPoint(x: 809, y: 218)
    let tick2 = CGPoint(x: 264, y: 249)
    let tick3 = CGPoint(x: 479, y: 249)
    let rest = CGPoint(x: 930, y: 612)

    let b = Board()
    b.move(0, downloadKey)
    b.chapter("Download")
    for f in late { b.hold(progressName(f), 0.3) }
    b.chapter("Done")
    let doneAt = b.hold("done", 2.6)
    b.move(doneAt + 0.2, downloadKey)
    b.move(doneAt + 1.3, rest)
    b.chapter("Connect")
    let camerasAt = b.hold("cameras", 2.1)
    b.move(camerasAt + 0.5, rest)
    b.move(camerasAt + 1.5, connectKey)
    b.click(camerasAt + 1.85, connectKey)
    b.chapter("Link")
    let connectingAt = b.hold("c-bluetooth", 0.55)
    b.hold("c-pairing", 0.75)
    b.hold("c-wifi", 0.9)
    b.hold("c-datalink", 0.8)
    b.move(connectingAt + 0.4, connectKey)
    b.chapter("Pick")
    let lib0 = b.hold("lib-0", 1.2)
    b.move(lib0 - 0.5, CGPoint(x: 420, y: 420))
    b.move(lib0 + 0.75, tick2)
    b.click(lib0 + 1.05, tick2)
    let lib1 = b.hold("lib-1", 0.75)
    b.move(lib1 + 0.5, tick3)
    b.click(lib1 + 0.62, tick3)
    let lib2 = b.hold("lib-2", 1.0)
    b.move(lib2 + 0.7, downloadKey)
    b.click(lib2 + 0.86, downloadKey)
    b.chapter("Download")
    for f in early { b.hold(progressName(f), 0.3) }
    b.move(b.total, downloadKey)
    return b
}

/// Record, stop, try Slow-mo, back to Video. Starts recording, like the still it replaces.
func live() throws -> Board {
    for sec in 0...4 { try shot("rec-\(sec)", "camera", ["OSMOTIC_DEMO_REC": "\(sec)"]) }
    try shot("idle-video", "camera", ["OSMOTIC_DEMO_REC": "off"])
    try shot("idle-slowmo", "camera", ["OSMOTIC_DEMO_REC": "off", "OSMOTIC_DEMO_CAPTURE": "slowmo"])

    let shutter = CGPoint(x: 1034, y: 697)
    let video = CGPoint(x: 52, y: 699)
    let slowmo = CGPoint(x: 190, y: 697)

    let b = Board()
    b.move(0, shutter)
    b.chapter("Record")
    for sec in 1...4 { b.hold("rec-\(sec)", 1.0) }
    b.click(b.total - 0.2, shutter)
    b.chapter("Stop")
    let stopped = b.hold("idle-video", 1.1)
    b.move(stopped + 0.2, shutter)
    b.move(stopped + 0.9, slowmo)
    b.click(stopped + 1.0, slowmo)
    b.chapter("Mode")
    let slow = b.hold("idle-slowmo", 1.5)
    b.move(slow + 0.8, video)
    b.click(slow + 1.35, video)
    let back = b.hold("idle-video", 1.3)
    b.move(back + 0.95, shutter)
    b.click(back + 1.15, shutter)
    b.chapter("Record")
    b.hold("rec-0", 1.0)
    b.move(b.total, shutter)
    return b
}

// ---- Drawing -------------------------------------------------------------------------------------

func context() -> CGContext {
    CGContext(
        data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

/// The window for one state: the title band with its buttons, the app's render under it.
func base(_ name: String) -> CGImage {
    let img = NSImage(contentsOf: raw.appendingPathComponent("\(name).png"))!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    let c = context()
    c.interpolationQuality = .high
    // The band and the spare bottom row take the plate's colour (its top row).
    let plate = NSBitmapImageRep(cgImage: img).colorAt(x: img.width / 2, y: 2) ?? NSColor(white: 0.14, alpha: 1)
    c.setFillColor(plate.cgColor)
    c.fill(CGRect(x: 0, y: 0, width: W, height: H))
    c.draw(img, in: CGRect(x: 0, y: 1, width: W, height: bodyH))
    let lights: [(CGFloat, CGFloat, CGFloat)] = [(255, 95, 87), (254, 188, 46), (40, 200, 64)]
    for (i, l) in lights.enumerated() {
        let cx = CGFloat(16 + 23 * i) * s, cy = CGFloat(H) - 16 * s, r = 6 * s
        c.setFillColor(CGColor(srgbRed: l.0 / 255, green: l.1 / 255, blue: l.2 / 255, alpha: 1))
        c.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
        c.setStrokeColor(CGColor(gray: 0, alpha: 0.18))
        c.setLineWidth(1)
        c.strokeEllipse(in: CGRect(x: cx - r + 0.5, y: cy - r + 0.5, width: r * 2 - 1, height: r * 2 - 1))
    }
    return c.makeImage()!
}

/// Window points to output pixels (CoreGraphics' origin is the bottom left).
func px(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * s, y: CGFloat(1 + bodyH) - p.y * s) }

/// The arrow pointer, tip at `tip`: black with a white outline and a soft shadow, as macOS draws it.
func pointer(_ c: CGContext, tip: CGPoint, scale k: CGFloat) {
    let shape: [CGPoint] = [(0, 0), (0, 17), (4.2, 13.2), (7.2, 19.8), (9.9, 18.6), (7, 12.2), (12.6, 12.2)]
        .map { CGPoint(x: $0.0, y: $0.1) }
    let path = CGMutablePath()
    for (i, p) in shape.enumerated() {
        let q = CGPoint(x: tip.x + p.x * 1.45 * s * k, y: tip.y - p.y * 1.45 * s * k)
        if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
    }
    path.closeSubpath()
    // The white outline first (it sits half outside the shape), shadowed; then the black body.
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 4, color: CGColor(gray: 0, alpha: 0.5))
    c.setStrokeColor(CGColor(gray: 1, alpha: 1))
    c.setLineWidth(3.2)
    c.setLineJoin(.round)
    c.addPath(path)
    c.strokePath()
    c.restoreGState()
    c.setFillColor(CGColor(gray: 0, alpha: 1))
    c.addPath(path)
    c.fillPath()
}

func smooth(_ x: Double) -> Double { x * x * (3 - 2 * x) }

func cursor(_ keys: [Key], at t: Double) -> CGPoint {
    guard let next = keys.firstIndex(where: { $0.t >= t }) else { return keys.last!.at }
    if next == 0 { return keys[0].at }
    let a = keys[next - 1], b = keys[next]
    let u = b.t > a.t ? smooth((t - a.t) / (b.t - a.t)) : 1
    return CGPoint(x: a.at.x + (b.at.x - a.at.x) * u, y: a.at.y + (b.at.y - a.at.y) * u)
}

func encode(_ board: Board, video: String, poster: String) throws {
    let bases = Dictionary(uniqueKeysWithValues: Set(board.steps.map(\.image)).map { ($0, base($0)) })
    let keys = board.keys.sorted { $0.t < $1.t }
    let frames = Int((board.total * fps).rounded())
    let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.fileExists(atPath: $0) }!
    let pipe = Pipe()
    let mp4 = images.appendingPathComponent(video)
    let encoder = try run(
        ffmpeg,
        [
            "-y", "-f", "rawvideo", "-pix_fmt", "rgba", "-s", "\(W)x\(H)", "-r", "\(Int(fps))", "-i", "-",
            "-an", "-c:v", "libx264", "-preset", "slow", "-crf", "24", "-tune", "animation",
            "-pix_fmt", "yuv420p", "-movflags", "+faststart", mp4.path,
        ], stdin: pipe, wait: false)

    let c = context()
    for n in 0..<frames {
        let t = Double(n) / fps
        let step = board.steps.last { $0.start <= t } ?? board.steps[0]
        c.draw(bases[step.image]!, in: CGRect(x: 0, y: 0, width: W, height: H))
        // A click: the pointer dips for a moment and a ring spreads from its tip.
        var k: CGFloat = 1
        for key in keys where key.click && t >= key.t && t < key.t + 0.45 {
            let u = (t - key.t) / 0.45
            if t < key.t + 0.12 { k = 0.86 }
            let r = (8 + 22 * u) * Double(s)
            let tip = px(key.at)
            c.setStrokeColor(CGColor(srgbRed: 1, green: 0.57, blue: 0.2, alpha: 0.75 * (1 - u)))
            c.setLineWidth(2.5)
            c.strokeEllipse(in: CGRect(x: tip.x - r, y: tip.y - r, width: r * 2, height: r * 2))
        }
        pointer(c, tip: px(cursor(keys, at: t)), scale: k)
        pipe.fileHandleForWriting.write(Data(bytes: c.data!, count: W * H * 4))
        if n == 0 {
            let png = work.appendingPathComponent("\(poster).png")
            try NSBitmapImageRep(cgImage: c.makeImage()!).representation(using: .png, properties: [:])!.write(to: png)
            try run("/usr/bin/env", ["cwebp", "-quiet", "-q", "86", png.path, "-o", images.appendingPathComponent("\(poster).webp").path])
        }
    }
    pipe.fileHandleForWriting.closeFile()
    encoder.waitUntilExit()
    let size = (try? FileManager.default.attributesOfItem(atPath: mp4.path)[.size] as? Int) ?? 0
    print("\(mp4.path): \(frames) frames, \(String(format: "%.1f", board.total)) s, \(size / 1024) KB")
    let steps = board.chapters.map { "\(String(format: "%g", ($0.0 * 100).rounded() / 100)):\($0.1)" }.joined(separator: ",")
    print("  data-steps=\"\(steps)\"")
}

for name in wanted {
    switch name {
    case "hero": try encode(try hero(), video: "demo.mp4", poster: "demo-poster")
    case "live": try encode(try live(), video: "live.mp4", poster: "live-poster")
    default: fatalError("unknown storyboard \(name): hero or live")
    }
}
