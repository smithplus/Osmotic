// Renders Resources/AppIcon.icns and docs/images/icon.png: the wordmark with "smotic" removed, so
// just "o." (the app's ink and orange), on the same dark graphite plate as the app and the landing
// page, grain included.
// Run: swift scripts/make_icon.swift [repo root]
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

struct RNG { var s: UInt64; mutating func next() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / Double(1 << 53) } }

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

/// Apple's icon shape is a continuous-corner squircle; a superellipse (n = 5) is a close match.
func squircle(in r: NSRect) -> NSBezierPath {
    let path = NSBezierPath()
    let n = 5.0, steps = 360
    for i in 0...steps {
        let t = Double(i) / Double(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = pow(abs(c), 2 / n) * (c < 0 ? -1 : 1), y = pow(abs(s), 2 / n) * (s < 0 ? -1 : 1)
        let p = NSPoint(x: r.midX + x * r.width / 2, y: r.midY + y * r.height / 2)
        i == 0 ? path.move(to: p) : path.line(to: p)
    }
    path.close()
    return path
}

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    // macOS grid: an 824-pt shape centered on a 1024 canvas.
    let inset = s * 0.0977
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let plate = squircle(in: rect)

    // Contact shadow under the plate.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.32)
    shadow.shadowBlurRadius = s * 0.022
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.010)
    shadow.set()
    rgb(33, 33, 32).setFill()
    plate.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    plate.addClip()
    // The same plate as the page: a dark graphite gradient with a fine grain over it.
    NSGradient(colors: [rgb(38, 38, 37), rgb(25, 25, 24)], atLocations: [0, 1], colorSpace: .sRGB)!
        .draw(in: rect, angle: -90)
    var grain = RNG(s: 99)
    let step = max(1, s / 400)  // fine specks: ~2.5 px at 1024, 1 px at Dock sizes
    var y = rect.minY
    while y < rect.maxY {
        var x = rect.minX
        while x < rect.maxX {
            let v = grain.next() * 2 - 1
            if abs(v) > 0.35 {
                (v > 0 ? NSColor.white : NSColor.black).withAlphaComponent(abs(v) * 0.04).setFill()
                NSBezierPath(rect: NSRect(x: x, y: y, width: step, height: step)).fill()
            }
            x += step
        }
        y += step
    }
    NSGraphicsContext.restoreGraphicsState()

    // Edge: a lit lip on top, fading down the sides.
    NSGraphicsContext.saveGraphicsState()
    plate.addClip()
    let edge = squircle(in: rect.insetBy(dx: s * 0.002, dy: s * 0.002))
    edge.lineWidth = max(1, s * 0.004)
    let edgeImage = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
        NSColor.white.setStroke()
        edge.stroke()
        return true
    }
    let mask = NSGradient(colors: [NSColor.white.withAlphaComponent(0.16), NSColor.white.withAlphaComponent(0.02)])!
    NSGraphicsContext.current?.cgContext.saveGState()
    if let cg = edgeImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
        NSGraphicsContext.current?.cgContext.clip(to: CGRect(x: 0, y: 0, width: s, height: s), mask: cg)
        mask.draw(in: rect, angle: -90)
    }
    NSGraphicsContext.current?.cgContext.restoreGState()
    NSGraphicsContext.restoreGraphicsState()

    // The wordmark's own weight and ink, so the icon is literally "osmotic" minus "smotic".
    let font = NSFont.systemFont(ofSize: s * 0.52, weight: .heavy)
    let ink = rgb(232, 229, 222)
    let o = NSAttributedString(string: "o", attributes: [.font: font, .foregroundColor: ink])
    let line = CTLineCreateWithAttributedString(o)
    let glyph = CTLineGetImageBounds(line, NSGraphicsContext.current!.cgContext)

    // The dot: a period on the baseline, as wide as the o's stroke.
    let dotD = glyph.width * 0.27
    let gap = glyph.width * 0.10
    let groupW = glyph.width + gap + dotD
    // Optical centering: the dot is light, so the pair sits a little right of true center.
    let originX = (s - groupW) / 2 - glyph.minX + s * 0.012
    let originY = (s - glyph.height) / 2 - glyph.minY

    NSGraphicsContext.saveGraphicsState()
    let printShadow = NSShadow()  // printed on metal: a hairline of shade under the ink
    printShadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
    printShadow.shadowBlurRadius = s * 0.006
    printShadow.shadowOffset = NSSize(width: 0, height: -s * 0.004)
    printShadow.set()
    let cg = NSGraphicsContext.current!.cgContext
    cg.textPosition = CGPoint(x: originX, y: originY)  // baseline origin, as measured above
    CTLineDraw(line, cg)
    NSGraphicsContext.restoreGraphicsState()

    // The dot: the wordmark's flat accent with the same soft glow, not a lit bead.
    let dotRect = NSRect(x: originX + glyph.maxX + gap, y: originY + glyph.minY, width: dotD, height: dotD)
    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = rgb(238, 92, 36, 0.45)
    glow.shadowBlurRadius = s * 0.025
    glow.shadowOffset = .zero
    glow.set()
    rgb(238, 92, 36).setFill()
    NSBezierPath(ovalIn: dotRect).fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try render(256).write(to: root.appendingPathComponent("docs/images/icon.png"))
try render(1024).write(to: root.appendingPathComponent("build/icon-1024.png"))
try render(64).write(to: root.appendingPathComponent("build/icon-64.png"))
let out = root.appendingPathComponent("Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run()
p.waitUntilExit()
print(out.path)
