// The README's and the landing's screenshots, rendered by the app in demo mode and framed like a
// macOS window: the title-bar band with its three buttons, rounded corners, a hairline and a soft
// shadow on a transparent margin. Synthetic footage only (make_scenes.swift); never anyone's own.
//
//   scripts/package_app.sh && swift scripts/make_shots.swift .
//   → docs/images/{library,files,cameras,connecting,live,webcam}.png + .webp
//
// Regenerate them whenever the UI changes. Needs cwebp.
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let work = root.appendingPathComponent("build/shots")
let scenes = root.appendingPathComponent("build/video/scenes")
let images = root.appendingPathComponent("docs/images")
let fixtures = root.appendingPathComponent("Tests/OsmoticCoreTests/Fixtures")
try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

func run(_ exe: String, _ args: [String], env: [String: String] = [:]) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    p.waitUntilExit()
}

if !FileManager.default.fileExists(atPath: scenes.appendingPathComponent("00-sunset-sea.jpg").path) {
    try run("/usr/bin/env", ["swift", root.appendingPathComponent("scripts/make_scenes.swift").path, scenes.path])
}

struct Shot {
    let name: String
    let screen: String
    let fixture: String
    /// Rows of the 2240×1480 render to keep, from the top: the screens with little on them end early.
    let crop: Int
    /// Width of the window in the output, in pixels.
    let width: Double
}

let shots = [
    Shot(name: "library", screen: "library", fixture: "op3_15.bin", crop: 1480, width: 1400),
    Shot(name: "files", screen: "library", fixture: "op3_29.bin", crop: 1480, width: 1280),
    Shot(name: "cameras", screen: "cameras", fixture: "op3_15.bin", crop: 1000, width: 1280),
    Shot(name: "connecting", screen: "connecting", fixture: "op3_15.bin", crop: 960, width: 1280),
    Shot(name: "live", screen: "camera", fixture: "op3_15.bin", crop: 1480, width: 1280),
    Shot(name: "webcam", screen: "webcam", fixture: "op3_15.bin", crop: 780, width: 1280),
]

/// The window, framed: band + buttons on top of the render, then corners, hairline and shadow.
func frame(_ src: CGImage, crop: Int, width outW: Double) -> CGImage {
    let body = src.cropping(to: CGRect(x: 0, y: 0, width: src.width, height: min(crop, src.height)))!
    // The render starts under the title bar: add that band (32 pt at 2x) with the window buttons
    // where macOS puts them (x 9…69 pt, y 9…23 pt), so the shot reads like the real window.
    let band = 64
    let fullH = body.height + band
    let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    let full = CGContext(
        data: nil, width: src.width, height: fullH, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    full.draw(body, in: CGRect(x: 0, y: 0, width: src.width, height: body.height))
    let plate = NSBitmapImageRep(cgImage: body).colorAt(x: src.width / 2, y: 2) ?? NSColor(white: 0.14, alpha: 1)
    full.setFillColor(plate.cgColor)
    full.fill(CGRect(x: 0, y: body.height, width: src.width, height: band))
    let lights: [(CGFloat, CGFloat, CGFloat)] = [(255, 95, 87), (254, 188, 46), (40, 200, 64)]
    for (i, l) in lights.enumerated() {
        let cx = CGFloat(16 + 23 * i) * 2, cy = CGFloat(fullH) - 32, r: CGFloat = 12
        full.setFillColor(CGColor(srgbRed: l.0 / 255, green: l.1 / 255, blue: l.2 / 255, alpha: 1))
        full.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
        full.setStrokeColor(CGColor(gray: 0, alpha: 0.18))
        full.setLineWidth(1)
        full.strokeEllipse(in: CGRect(x: cx - r + 0.5, y: cy - r + 0.5, width: r * 2 - 1, height: r * 2 - 1))
    }
    let window = full.makeImage()!

    let scale = outW / Double(src.width)
    let w = outW, h = Double(fullH) * scale
    let pad = 44.0, radius = 20.0
    let ctx = CGContext(
        data: nil, width: Int(w + pad * 2), height: Int(h + pad * 2), bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let rect = CGRect(x: pad, y: pad, width: w, height: h)
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: CGColor(gray: 0, alpha: 0.45))
    ctx.addPath(path)
    ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.draw(window, in: rect)
    ctx.restoreGState()
    ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.10))
    ctx.setLineWidth(1)
    ctx.strokePath()
    return ctx.makeImage()!
}

for shot in shots {
    let rawURL = work.appendingPathComponent("\(shot.name)-raw.png")
    try? FileManager.default.removeItem(at: rawURL)
    try run(
        "/bin/bash",
        [root.appendingPathComponent("scripts/snapshot.sh").path, rawURL.path, shot.screen,
         fixtures.appendingPathComponent(shot.fixture).path],
        env: ["OSMOTIC_LANG": "en", "OSMOTIC_LOCALE": "en_US", "OSMOTIC_DEMO_THUMBS": scenes.path])
    guard let img = NSImage(contentsOf: rawURL)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        fatalError("no render for \(shot.name)")
    }
    let png = images.appendingPathComponent("\(shot.name).png")
    try NSBitmapImageRep(cgImage: frame(img, crop: shot.crop, width: shot.width))
        .representation(using: .png, properties: [:])!.write(to: png)
    try run("/usr/bin/env", ["cwebp", "-quiet", "-q", "82", png.path, "-o", images.appendingPathComponent("\(shot.name).webp").path])
    print(png.path)
}
