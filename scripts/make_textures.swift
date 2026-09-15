// Material textures for the landing page (site/textures/): seamless 128-px tiles, mostly transparent.
//   grain.png   : fine speckle, for the plate and the plastic of the keys
//   scratches.png : a few faint hairlines, for the metal panels (long streaks read as wood)
// White noise tiles seamlessly; the scratches are drawn again at +/- one tile so they tile too.
// Run: swift scripts/make_textures.swift . && for f in site/textures/*.png; do cwebp -quiet -lossless -z 9 "$f" -o "${f%.png}.webp"; done && rm site/textures/*.png
// Only the .webp files are committed (3 KB and 6 KB); the PNGs are intermediate.
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let out = root.appendingPathComponent("site/textures")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let n = 128

struct RNG { var s: UInt64; mutating func next() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / Double(1 << 53) } }

/// Values in -1…1 become light (above 0) or dark (below 0) specks with alpha up to `strength`.
/// Quantized to a few levels so the PNG stays small.
func write(_ values: [Double], strength: Double, name: String) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: n * 4, bitsPerPixel: 32)!
    let px = rep.bitmapData!
    for i in 0..<(n * n) {
        let v = max(-1, min(1, values[i]))
        let level = (abs(v) * 6).rounded() / 6  // 7 levels of alpha
        let a = UInt8(level * strength * 255)
        let c: UInt8 = v >= 0 ? 255 : 0
        // Premultiplied RGBA.
        let pc = UInt8(Double(c) * Double(a) / 255)
        px[i * 4] = pc; px[i * 4 + 1] = pc; px[i * 4 + 2] = pc; px[i * 4 + 3] = a
    }
    try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
    print(out.appendingPathComponent(name).path)
}

// Grain: independent speckles, a little sparse so it reads as material, not static.
var r = RNG(s: 7)
var grain = [Double](repeating: 0, count: n * n)
for i in 0..<(n * n) {
    let u = r.next() * 2 - 1
    grain[i] = abs(u) > 0.35 ? u : 0
}
try write(grain, strength: 0.022, name: "grain.png")

// Scratches: a handful of faint hairlines on a 256-px tile, drawn again one tile over in each
// direction so nothing is cut at the seam. Long parallel streaks read as wood, so these are short,
// sparse and barely there.
do {
    let m = 256
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: m, pixelsHigh: m, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: m * 4, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setLineWidth(1)
    ctx.setLineCap(.round)
    var s = RNG(s: 2026)
    for _ in 0..<14 {
        let x = s.next() * Double(m), y = s.next() * Double(m)
        let len = 24 + s.next() * 120
        let angle = (s.next() - 0.5) * 0.5  // near-horizontal, but never parallel
        let light = s.next() > 0.45
        ctx.setStrokeColor(CGColor(gray: light ? 1 : 0, alpha: light ? 0.05 : 0.045))
        for dx in [-Double(m), 0, Double(m)] {
            for dy in [-Double(m), 0, Double(m)] {
                ctx.move(to: CGPoint(x: x + dx, y: y + dy))
                ctx.addLine(to: CGPoint(x: x + dx + cos(angle) * len, y: y + dy + sin(angle) * len))
                ctx.strokePath()
            }
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("scratches.png"))
    print(out.appendingPathComponent("scratches.png").path)
}
