// Material textures for the landing page (site/textures/): seamless 128-px tiles, mostly transparent.
//   grain.png   : fine speckle, for the plate and the plastic of the keys
//   brushed.png : horizontal streaks, for the metal panels (the app's BrushedMetal, in miniature)
// White noise tiles seamlessly; the brushed streaks are blurred with wrap-around so they tile too.
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

// Brushed: per-row noise blurred along x (wrapping), plus a slow per-row tone so streaks vary.
var brushed = [Double](repeating: 0, count: n * n)
let radius = 18
for y in 0..<n {
    let rowTone = (r.next() * 2 - 1) * 0.35
    let raw = (0..<n).map { _ in r.next() * 2 - 1 }
    for x in 0..<n {
        var sum = 0.0
        for k in -radius...radius { sum += raw[(x + k + n) % n] }
        brushed[y * n + x] = sum / Double(radius * 2 + 1) * 3.2 + rowTone
    }
}
try write(brushed, strength: 0.035, name: "brushed.png")
