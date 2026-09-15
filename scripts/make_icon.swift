// Renders Resources/AppIcon.icns and docs/images/icon.png: the wordmark's "o." — a lowercase o and the
// orange dot — printed on a graphite squircle, the same plate as the app.
// Run: swift scripts/make_icon.swift [repo root]
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

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
    // The app's plate, lit from above: a quiet graphite gradient.
    NSGradient(colors: [rgb(64, 64, 62), rgb(44, 44, 43), rgb(30, 30, 29)], atLocations: [0, 0.55, 1],
               colorSpace: .sRGB)!.draw(in: rect, angle: -90)
    // A soft pool of light in the upper half, like brushed metal under a lamp.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.06), NSColor.white.withAlphaComponent(0)])!
        .draw(fromCenter: NSPoint(x: rect.midX, y: rect.maxY), radius: 0,
              toCenter: NSPoint(x: rect.midX, y: rect.maxY), radius: rect.width * 0.8, options: [])
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

    // The "o": bold rather than the wordmark's heavy, so the counter stays open at Dock sizes.
    let font = NSFont.systemFont(ofSize: s * 0.52, weight: .bold)
    let ink = rgb(236, 233, 226)
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

    let dotRect = NSRect(x: originX + glyph.maxX + gap, y: originY + glyph.minY, width: dotD, height: dotD)
    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = rgb(238, 92, 36, 0.55)
    glow.shadowBlurRadius = s * 0.03
    glow.shadowOffset = .zero
    glow.set()
    rgb(222, 78, 24).setFill()
    NSBezierPath(ovalIn: dotRect).fill()
    NSGraphicsContext.restoreGraphicsState()
    // Lit from above-left, like the app's LEDs.
    NSGradient(colors: [rgb(255, 150, 90), rgb(236, 88, 30), rgb(190, 60, 14)], atLocations: [0, 0.5, 1],
               colorSpace: .sRGB)!
        .draw(in: NSBezierPath(ovalIn: dotRect), relativeCenterPosition: NSPoint(x: -0.35, y: 0.4))

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
