// The landing's hero video: one session with a camera (connect, tick two clips, download them),
// rendered frame by frame by the app itself in demo mode and stitched into a loop with ffmpeg.
// No screen recording is involved: every picture is the app drawing its own window (snapshot.sh),
// with synthetic footage (make_scenes.swift). Only the pointer and its click rings are added here.
//
//   scripts/package_app.sh && swift scripts/make_demo_video.swift .
//   → docs/images/demo.mp4 (H.264, 1400×966, 30 fps, no audio) and docs/images/demo-poster.webp
//
// The loop starts mid-download, so its first frame (the poster) is the same view the page showed
// before as a still. Needs ffmpeg and cwebp.
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
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
let bodyH = 925, bandH = 40

func run(_ exe: String, _ args: [String], env: [String: String] = [:], stdin: Pipe? = nil) throws -> Process {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    if let stdin { p.standardInput = stdin }
    try p.run()
    return p
}

// ---- 1. The frames, from the app ---------------------------------------------------------------

if !FileManager.default.fileExists(atPath: scenes.appendingPathComponent("00-sunset-sea.jpg").path) {
    let p = try run("/usr/bin/env", ["swift", root.appendingPathComponent("scripts/make_scenes.swift").path, scenes.path])
    p.waitUntilExit()
}

/// Renders one demo state to raw/<name>.png unless it's already there.
func shot(_ name: String, _ screen: String, _ env: [String: String] = [:]) throws {
    let out = raw.appendingPathComponent("\(name).png")
    if FileManager.default.fileExists(atPath: out.path) { return }
    let p = try run(
        "/bin/bash", [root.appendingPathComponent("scripts/snapshot.sh").path, out.path, screen, fixture],
        env: env.merging([
            "OSMOTIC_LANG": "en", "OSMOTIC_LOCALE": "en_US", "OSMOTIC_DEMO_THUMBS": scenes.path,
            "OSMOTIC_SNAPSHOT_DELAY": "1.5",
        ]) { $1 })
    p.waitUntilExit()
    guard FileManager.default.fileExists(atPath: out.path) else { fatalError("no render for \(name)") }
    print("rendered \(name)")
}

func progressName(_ f: Double) -> String { String(format: "p-%03d", Int((f * 100).rounded())) }
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

// ---- 2. The storyboard -------------------------------------------------------------------------

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

var steps: [Step] = []
var total = 0.0
@discardableResult
func hold(_ image: String, _ seconds: Double) -> Double {
    steps.append(Step(image: image, start: total, seconds: seconds))
    total += seconds
    return total - seconds
}

// Where things are on the 1120×740 window (from the renders).
let downloadKey = CGPoint(x: 1018, y: 139)
let connectKey = CGPoint(x: 809, y: 218)
let tick2 = CGPoint(x: 264, y: 249)
let tick3 = CGPoint(x: 479, y: 249)
let rest = CGPoint(x: 930, y: 612)

var keys: [Key] = [Key(t: 0, at: downloadKey)]
for f in late { hold(progressName(f), 0.3) }
let doneAt = hold("done", 2.6)
keys.append(Key(t: doneAt + 0.2, at: downloadKey))
keys.append(Key(t: doneAt + 1.3, at: rest))
let camerasAt = hold("cameras", 2.1)
keys.append(Key(t: camerasAt + 0.5, at: rest))
keys.append(Key(t: camerasAt + 1.5, at: connectKey))
keys.append(Key(t: camerasAt + 1.85, at: connectKey, click: true))
let connectingAt = hold("c-bluetooth", 0.55)
hold("c-pairing", 0.75)
hold("c-wifi", 0.9)
hold("c-datalink", 0.8)
keys.append(Key(t: connectingAt + 0.4, at: connectKey))
let lib0 = hold("lib-0", 1.2)
keys.append(Key(t: lib0 - 0.5, at: CGPoint(x: 420, y: 420)))
keys.append(Key(t: lib0 + 0.75, at: tick2))
keys.append(Key(t: lib0 + 1.05, at: tick2, click: true))
let lib1 = hold("lib-1", 0.75)
keys.append(Key(t: lib1 + 0.5, at: tick3))
keys.append(Key(t: lib1 + 0.62, at: tick3, click: true))
let lib2 = hold("lib-2", 1.0)
keys.append(Key(t: lib2 + 0.7, at: downloadKey))
keys.append(Key(t: lib2 + 0.86, at: downloadKey, click: true))
for f in early { hold(progressName(f), 0.3) }
keys.append(Key(t: total, at: downloadKey))

// ---- 3. Drawing ---------------------------------------------------------------------------------

func cgImage(_ url: URL) -> CGImage {
    NSImage(contentsOf: url)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
}
func context() -> CGContext {
    CGContext(
        data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

/// The window for one state: the title band with its buttons, the app's render under it.
func base(_ name: String) -> CGImage {
    let img = cgImage(raw.appendingPathComponent("\(name).png"))
    let c = context()
    c.interpolationQuality = .high
    // The band and the spare bottom row take the plate's colour (its top row).
    let rep = NSBitmapImageRep(cgImage: img)
    let plate = rep.colorAt(x: img.width / 2, y: 2) ?? NSColor(white: 0.14, alpha: 1)
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

/// A plain arrow pointer, tip at `tip`: white with a dark outline, like any desktop's.
func pointer(_ c: CGContext, tip: CGPoint, scale k: CGFloat) {
    let shape: [CGPoint] = [(0, 0), (0, 17), (4.2, 13.2), (7.2, 19.8), (9.9, 18.6), (7, 12.2), (12.6, 12.2)]
        .map { CGPoint(x: $0.0, y: $0.1) }
    let path = CGMutablePath()
    for (i, p) in shape.enumerated() {
        let q = CGPoint(x: tip.x + p.x * 1.45 * s * k, y: tip.y - p.y * 1.45 * s * k)
        if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
    }
    path.closeSubpath()
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -2), blur: 5, color: CGColor(gray: 0, alpha: 0.45))
    c.setFillColor(CGColor(gray: 1, alpha: 1))
    c.addPath(path)
    c.fillPath()
    c.restoreGState()
    c.setStrokeColor(CGColor(gray: 0, alpha: 0.9))
    c.setLineWidth(1.4)
    c.setLineJoin(.round)
    c.addPath(path)
    c.strokePath()
}

func smooth(_ x: Double) -> Double { x * x * (3 - 2 * x) }

func cursor(at t: Double) -> CGPoint {
    guard let next = keys.firstIndex(where: { $0.t >= t }) else { return keys.last!.at }
    if next == 0 { return keys[0].at }
    let a = keys[next - 1], b = keys[next]
    let u = b.t > a.t ? smooth((t - a.t) / (b.t - a.t)) : 1
    return CGPoint(x: a.at.x + (b.at.x - a.at.x) * u, y: a.at.y + (b.at.y - a.at.y) * u)
}

let bases = Dictionary(uniqueKeysWithValues: Set(steps.map(\.image)).map { ($0, base($0)) })
let frames = Int((total * fps).rounded())

let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.fileExists(atPath: $0) }!
let pipe = Pipe()
let mp4 = images.appendingPathComponent("demo.mp4")
let encoder = try run(
    ffmpeg,
    [
        "-y", "-f", "rawvideo", "-pix_fmt", "rgba", "-s", "\(W)x\(H)", "-r", "\(Int(fps))", "-i", "-",
        "-an", "-c:v", "libx264", "-preset", "slow", "-crf", "24", "-tune", "animation",
        "-pix_fmt", "yuv420p", "-movflags", "+faststart", mp4.path,
    ], stdin: pipe)

let c = context()
for n in 0..<frames {
    let t = Double(n) / fps
    let step = steps.last { $0.start <= t } ?? steps[0]
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
    pointer(c, tip: px(cursor(at: t)), scale: k)
    let data = Data(bytes: c.data!, count: W * H * 4)
    pipe.fileHandleForWriting.write(data)
    if n == 0 {
        let poster = work.appendingPathComponent("poster.png")
        try NSBitmapImageRep(cgImage: c.makeImage()!).representation(using: .png, properties: [:])!.write(to: poster)
        let p = try run(
            "/usr/bin/env", ["cwebp", "-quiet", "-q", "86", poster.path, "-o", images.appendingPathComponent("demo-poster.webp").path])
        p.waitUntilExit()
    }
}
pipe.fileHandleForWriting.closeFile()
encoder.waitUntilExit()
let size = (try? FileManager.default.attributesOfItem(atPath: mp4.path)[.size] as? Int) ?? 0
print("\(mp4.path): \(frames) frames, \(String(format: "%.1f", total)) s, \(size / 1024) KB")
