// One illustration per install step, for the landing page (docs/images/step-1..3.png, then WebP).
//   1. drag Osmotic to Applications: the app icon, a dotted path, a folder
//   2. the first launch: the Settings path as an amber readout with the key to press
//   3. connect: a crop of the app's own Cameras screen (a real screenshot)
// Steps 1 and 2 are diagrams in the app's own style on purpose: macOS windows and dialogs can't be
// captured here (no screen-recording permission) and a drawn copy of an Apple dialog would be a
// fake screenshot.
// Run: swift scripts/make_install_steps.swift . && for f in docs/images/step-*.png; do cwebp -quiet -q 88 "$f" -o "${f%.png}.webp"; done
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let images = root.appendingPathComponent("docs/images")
let W: CGFloat = 900, H: CGFloat = 520  // 2x of the card's image area

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}
let ink = rgb(232, 229, 222), muted = rgb(160, 157, 150), amber = rgb(255, 146, 52)
let accentTop = rgb(206, 70, 20), accentBottom = rgb(180, 58, 14)

func mono(_ size: CGFloat, _ w: NSFont.Weight = .medium) -> NSFont { .monospacedSystemFont(ofSize: size, weight: w) }
func sans(_ size: CGFloat, _ w: NSFont.Weight) -> NSFont { .systemFont(ofSize: size, weight: w) }

@discardableResult
func text(_ s: String, _ font: NSFont, _ color: NSColor, x: CGFloat, y: CGFloat, width: CGFloat,
          tracking: CGFloat = 0, align: NSTextAlignment = .left, glow: NSColor? = nil) -> CGFloat {
    let p = NSMutableParagraphStyle()
    p.alignment = align
    var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: p, .kern: tracking]
    if let glow {
        let sh = NSShadow(); sh.shadowColor = glow; sh.shadowBlurRadius = 10; sh.shadowOffset = .zero
        attrs[.shadow] = sh
    }
    let a = NSAttributedString(string: s, attributes: attrs)
    let h = ceil(a.boundingRect(with: NSSize(width: width, height: 400), options: [.usesLineFragmentOrigin]).height)
    a.draw(with: NSRect(x: x, y: H - y - h, width: width, height: h), options: [.usesLineFragmentOrigin])
    return h
}

func plate() {
    NSGradient(colors: [rgb(40, 40, 39), rgb(28, 28, 27)])!.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)
}

/// A rounded slab in the app's metal, with the lit top edge.
func slab(_ rect: NSRect, radius: CGFloat = 18) {
    let r = NSRect(x: rect.minX, y: H - rect.maxY, width: rect.width, height: rect.height)
    let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.35); sh.shadowBlurRadius = 18
    sh.shadowOffset = NSSize(width: 0, height: -6); sh.set()
    NSGradient(colors: [rgb(52, 52, 51), rgb(42, 42, 41)])!.draw(in: path, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    NSColor.white.withAlphaComponent(0.09).setStroke()
    let top = NSBezierPath()
    top.move(to: NSPoint(x: r.minX + radius, y: r.maxY - 0.5))
    top.line(to: NSPoint(x: r.maxX - radius, y: r.maxY - 0.5))
    top.stroke()
}

func lcd(_ rect: NSRect, radius: CGFloat = 16) {
    let r = NSRect(x: rect.minX, y: H - rect.maxY, width: rect.width, height: rect.height)
    rgb(16, 16, 15).setFill()
    NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).addClip()
    // Scanlines, as on the page.
    NSColor.white.withAlphaComponent(0.016).setFill()
    var y = r.minY
    while y < r.maxY {
        NSBezierPath(rect: NSRect(x: r.minX, y: y, width: r.width, height: 1)).fill()
        y += 3
    }
    NSGraphicsContext.restoreGraphicsState()
}

/// A cassette key with its slot, as on the page.
func key(_ rect: NSRect, label: String, primary: Bool = false) {
    let slot = NSRect(x: rect.minX - 5, y: H - rect.maxY - 5, width: rect.width + 10, height: rect.height + 16)
    rgb(17, 17, 16).setFill()
    NSBezierPath(roundedRect: slot, xRadius: 8, yRadius: 8).fill()
    let travel: CGFloat = 8
    let face = NSRect(x: rect.minX, y: H - rect.maxY + travel, width: rect.width, height: rect.height)
    rgb(36, 36, 36).setFill()  // skirt
    NSBezierPath(roundedRect: NSRect(x: face.minX, y: face.minY - travel, width: face.width, height: face.height + travel),
                 xRadius: 4, yRadius: 4).fill()
    let path = NSBezierPath(roundedRect: face, xRadius: 4, yRadius: 4)
    NSGradient(colors: primary ? [accentTop, accentBottom] : [rgb(66, 66, 65), rgb(53, 53, 52)])!.draw(in: path, angle: -90)
    NSColor.white.withAlphaComponent(primary ? 0.3 : 0.12).setFill()
    NSBezierPath(rect: NSRect(x: face.minX + 3, y: face.maxY - 1.5, width: face.width - 6, height: 1.5)).fill()
    let f = sans(20, .semibold)
    let a = NSAttributedString(string: label.uppercased(), attributes: [
        .font: f, .foregroundColor: primary ? NSColor.white : ink, .kern: 1.8,
    ])
    a.draw(at: NSPoint(x: face.midX - a.size().width / 2, y: face.midY - a.size().height / 2))
}

func save(_ name: String, _ draw: () -> Void) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    plate()
    draw()
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: images.appendingPathComponent(name))
    print(images.appendingPathComponent(name).path)
}

// 1. Drag the app onto Applications.
try save("step-1.png") {
    if let icon = NSImage(contentsOf: root.appendingPathComponent("build/icon-1024.png")) {
        icon.draw(in: NSRect(x: 96, y: H - 300, width: 190, height: 190))
    }
    text("OSMOTIC", mono(19), muted, x: 96, y: 300, width: 200, tracking: 2.5, align: .center)

    // A dotted path between the two, like the app's LED runs.
    amber.withAlphaComponent(0.75).setFill()
    var x: CGFloat = 330
    while x < 560 {
        NSBezierPath(ovalIn: NSRect(x: x, y: H - 215, width: 7, height: 7)).fill()
        x += 22
    }
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 566, y: H - 212))
    head.line(to: NSPoint(x: 552, y: H - 202))
    head.line(to: NSPoint(x: 552, y: H - 222))
    head.close()
    amber.setFill()
    head.fill()

    // A folder in one stroke, the same glyph as the page's icon set.
    let fr = NSRect(x: 620, y: H - 300, width: 190, height: 150)
    let k = fr.width / 18  // the glyph spans 3…21 on a 24 grid
    func gp(_ gx: CGFloat, _ gy: CGFloat) -> NSPoint {  // glyph space (y down) to canvas (y up)
        NSPoint(x: fr.minX + (gx - 3) * k, y: fr.maxY - (gy - 6) * k)
    }
    let f = NSBezierPath()
    f.move(to: gp(3, 8))
    f.line(to: gp(3, 6.8))
    f.appendArc(from: gp(3, 6), to: gp(4.2, 6), radius: 1.2 * k)
    f.line(to: gp(9, 6))
    f.line(to: gp(11, 8))
    f.line(to: gp(19.8, 8))
    f.appendArc(from: gp(21, 8), to: gp(21, 9.2), radius: 1.2 * k)
    f.line(to: gp(21, 17.8))
    f.appendArc(from: gp(21, 19), to: gp(19.8, 19), radius: 1.2 * k)
    f.line(to: gp(4.2, 19))
    f.appendArc(from: gp(3, 19), to: gp(3, 17.8), radius: 1.2 * k)
    f.close()
    ink.withAlphaComponent(0.9).setStroke()
    f.lineWidth = 5
    f.lineJoinStyle = .round
    f.stroke()
    text("APPLICATIONS", mono(19), muted, x: 610, y: 300, width: 210, tracking: 2.5, align: .center)
}

// 2. The first launch: where to click, in the app's readout style.
try save("step-2.png") {
    lcd(NSRect(x: 70, y: 80, width: W - 140, height: 190))
    text("SYSTEM SETTINGS  ›  PRIVACY & SECURITY", mono(24), amber.withAlphaComponent(0.85), x: 110, y: 125,
         width: W - 220, tracking: 2.2, glow: amber.withAlphaComponent(0.3))
    text("SCROLL DOWN TO THE OSMOTIC NOTICE", mono(19), rgb(236, 228, 214, 0.5), x: 110, y: 185, width: W - 220, tracking: 2)
    key(NSRect(x: W / 2 - 150, y: 330, width: 300, height: 66), label: "Open Anyway", primary: true)
    text("ONCE, THE FIRST TIME", mono(18), muted, x: 0, y: 430, width: W, tracking: 2.4, align: .center)
}

// 3. Connect: the app's own Cameras screen.
try save("step-3.png") {
    guard let shot = NSImage(contentsOf: images.appendingPathComponent("cameras.png")),
        let cg = shot.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else { return }
    // The nearby-camera row with its Connect key, from the middle of the window.
    let cropW = Int(Double(cg.width) * 0.66), cropH = Int(Double(cg.height) * 0.30)
    guard let crop = cg.cropping(to: CGRect(x: Int(Double(cg.width) * 0.20), y: Int(Double(cg.height) * 0.34),
                                            width: cropW, height: cropH))
    else { return }
    let w = W - 120, h = w * CGFloat(cropH) / CGFloat(cropW)
    let r = NSRect(x: 60, y: (H - h) / 2, width: w, height: h)
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.45); sh.shadowBlurRadius = 24
    sh.shadowOffset = NSSize(width: 0, height: -8); sh.set()
    let clip = NSBezierPath(roundedRect: r, xRadius: 16, yRadius: 16)
    clip.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    clip.addClip()
    NSImage(cgImage: crop, size: r.size).draw(in: r)
    NSGraphicsContext.restoreGraphicsState()
    NSColor.white.withAlphaComponent(0.1).setStroke()
    NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 16, yRadius: 16).stroke()
}
