// One illustration per install step, for the landing page (docs/images/step-1..3.png, then WebP).
//   1. drag Osmotic to Applications: the disk image as Finder opens it (+ step-1.mp4, the drag itself)
//   2. the first launch: the Privacy & Security pane, drawn the way macOS lays it out
//   3. connect: the app's own Cameras screen (a real render), with the key to press marked
// Steps 1 and 2 are drawings: macOS windows can't be captured here (no screen-recording permission),
// so they copy the system's layout and colors, never Apple's own artwork.
// Run: swift scripts/make_install_steps.swift . && for f in docs/images/step-*.png; do cwebp -quiet -q 88 "$f" -o "${f%.png}.webp"; done
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let images = root.appendingPathComponent("docs/images")
let W: CGFloat = 900, H: CGFloat = 520  // 2x of the card's image area

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}
let amber = rgb(255, 146, 52)  // the page's pointer color

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

/// One picture on the plate. Rows are packed (no padding), so the pixels can go straight to ffmpeg.
func render(_ draw: () -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: Int(W) * 4, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    plate()
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func save(_ name: String, _ draw: () -> Void) throws {
    try render(draw).representation(using: .png, properties: [:])!.write(to: images.appendingPathComponent(name))
    print(images.appendingPathComponent(name).path)
}

/// The arrow pointer with its tip at `tip` (top-based): black with a white outline, as macOS draws it.
func pointer(tip: NSPoint, scale k: CGFloat = 1) {
    let shape: [(CGFloat, CGFloat)] = [(0, 0), (0, 17), (4.2, 13.2), (7.2, 19.8), (9.9, 18.6), (7, 12.2), (12.6, 12.2)]
    let path = NSBezierPath()
    for (i, p) in shape.enumerated() {
        let q = NSPoint(x: tip.x + p.0 * 1.6 * k, y: H - (tip.y + p.1 * 1.6 * k))
        if i == 0 { path.move(to: q) } else { path.line(to: q) }
    }
    path.close()
    // The white outline first (half of it falls outside the shape), shadowed; then the black body.
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.5); sh.shadowBlurRadius = 4
    sh.shadowOffset = NSSize(width: 0, height: -1.5); sh.set()
    NSColor.white.setStroke()
    path.lineWidth = 3.4
    path.lineJoinStyle = .round
    path.stroke()
    NSGraphicsContext.restoreGraphicsState()
    NSColor.black.setFill()
    path.fill()
}

func smooth(_ x: Double) -> Double { let t = min(1, max(0, x)); return t * t * (3 - 2 * t) }

/// Top-based rect (like `text`) to AppKit's bottom-based one.
func tr(_ r: NSRect) -> NSRect { NSRect(x: r.minX, y: H - r.maxY, width: r.width, height: r.height) }

/// A macOS window: rounded, with its shadow, a toolbar band and the three buttons at top left.
/// Drawn here because this Mac has no screen-recording permission, so system windows can't be
/// captured. It copies the system's layout and colors, never Apple's own artwork.
func macWindow(_ win: NSRect, title: String? = nil, toolbar: CGFloat = 0, fill: NSColor = rgb(30, 30, 32)) -> NSBezierPath {
    let path = NSBezierPath(roundedRect: tr(win), xRadius: 14, yRadius: 14)
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.55); sh.shadowBlurRadius = 34
    sh.shadowOffset = NSSize(width: 0, height: -10); sh.set()
    fill.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    if toolbar > 0 {
        rgb(48, 48, 50).setFill()
        NSBezierPath(rect: tr(NSRect(x: win.minX, y: win.minY, width: win.width, height: toolbar))).fill()
        NSColor.white.withAlphaComponent(0.08).setFill()
        NSBezierPath(rect: tr(NSRect(x: win.minX, y: win.minY + toolbar, width: win.width, height: 1))).fill()
    }
    for (i, c) in [rgb(255, 95, 86), rgb(255, 189, 46), rgb(39, 201, 63)].enumerated() {
        c.setFill()
        NSBezierPath(ovalIn: tr(NSRect(x: win.minX + 20 + CGFloat(i) * 22, y: win.minY + 18, width: 14, height: 14))).fill()
    }
    if let title {
        text(title, sans(14, .semibold), rgb(226, 226, 230), x: win.minX, y: win.minY + 17, width: win.width, align: .center)
    }
    return path
}

/// A folder in the shape and blue macOS uses (top-based rect).
func folder(_ rect: NSRect) {
    let fr = tr(rect)
    let tabW = fr.width * 0.48, tabH = fr.height * 0.17, r = fr.width * 0.07
    let back = NSBezierPath()
    back.appendRoundedRect(NSRect(x: fr.minX, y: fr.minY, width: fr.width, height: fr.height - tabH), xRadius: r, yRadius: r)
    // The tab sits on the back panel, left-aligned, as on macOS.
    let tab = NSBezierPath()
    tab.move(to: NSPoint(x: fr.minX + r, y: fr.maxY - tabH - fr.height * 0.06))
    tab.line(to: NSPoint(x: fr.minX + r, y: fr.maxY - 4))
    tab.appendArc(from: NSPoint(x: fr.minX + r, y: fr.maxY), to: NSPoint(x: fr.minX + r + 8, y: fr.maxY), radius: 6)
    tab.line(to: NSPoint(x: fr.minX + tabW - 8, y: fr.maxY))
    tab.line(to: NSPoint(x: fr.minX + tabW + 5, y: fr.maxY - tabH - 3))
    tab.close()
    NSGradient(colors: [rgb(96, 173, 235), rgb(58, 138, 214)])!.draw(in: tab, angle: -90)
    NSGradient(colors: [rgb(120, 190, 244), rgb(70, 150, 224)])!.draw(in: back, angle: -90)
    // The front panel, a shade lighter, like the open folder's face.
    let front = NSBezierPath(roundedRect: NSRect(x: fr.minX, y: fr.minY, width: fr.width, height: fr.height - tabH - fr.height * 0.11),
                             xRadius: r, yRadius: r)
    NSGradient(colors: [rgb(150, 210, 250), rgb(96, 173, 235)])!.draw(in: front, angle: -90)
    NSColor.white.withAlphaComponent(0.35).setStroke()
    front.lineWidth = 1.5
    front.stroke()
}

/// A plain text document, the way the DMG's note shows up (top-based rect).
func document(_ rect: NSRect) {
    let r = tr(rect)
    let fold = r.width * 0.28
    let page = NSBezierPath()
    page.move(to: NSPoint(x: r.minX, y: r.minY))
    page.line(to: NSPoint(x: r.minX, y: r.maxY))
    page.line(to: NSPoint(x: r.maxX - fold, y: r.maxY))
    page.line(to: NSPoint(x: r.maxX, y: r.maxY - fold))
    page.line(to: NSPoint(x: r.maxX, y: r.minY))
    page.close()
    rgb(246, 246, 248).setFill()
    page.fill()
    // The folded corner.
    let corner = NSBezierPath()
    corner.move(to: NSPoint(x: r.maxX - fold, y: r.maxY))
    corner.line(to: NSPoint(x: r.maxX - fold, y: r.maxY - fold))
    corner.line(to: NSPoint(x: r.maxX, y: r.maxY - fold))
    corner.close()
    rgb(206, 208, 214).setFill()
    corner.fill()
    // A few lines of text.
    rgb(176, 178, 186).setFill()
    var y = r.maxY - fold - 14
    var i = 0
    while y > r.minY + 12 {
        let w = (i % 4 == 3) ? r.width * 0.4 : r.width * 0.64
        NSBezierPath(rect: NSRect(x: r.minX + r.width * 0.16, y: y, width: w, height: 4)).fill()
        y -= 14
        i += 1
    }
}

/// An icon with its name under it, as Finder lays out an icon view.
func iconItem(centerX: CGFloat, top: CGFloat, size: CGFloat, labelY: CGFloat, label: String, draw: (NSRect) -> Void) {
    draw(NSRect(x: centerX - size / 2, y: top, width: size, height: size))
    text(label, sans(15, .regular), rgb(230, 230, 234), x: centerX - 110, y: labelY, width: 220, align: .center)
}

// 1. The disk image as Finder opens it: drag the app onto Applications. The still is the window at
// rest; the clip (step-1.mp4, played once on the page) is the same window with the drag happening.
let dmg = NSRect(x: 58, y: 66, width: W - 116, height: 388)
let iconRow = dmg.minY + 122
let appCenter = NSPoint(x: dmg.minX + 150, y: iconRow + 62)
let folderCenter = NSPoint(x: dmg.midX + 20, y: iconRow + 70)
let appIcon = NSImage(contentsOf: root.appendingPathComponent("build/icon-1024.png"))

/// `t` is the clip's time in seconds; nil draws the still (no pointer, the guide showing).
func step1(_ t: Double?) {
    let win = dmg
    _ = macWindow(win, title: "Osmotic", toolbar: 52)
    let row = iconRow
    let labelY = row + 138
    // The drop target lights as the icon arrives over it, the way Finder shows it.
    let over = t.map { smooth(($0 - 1.55) / 0.2) * (1 - smooth(($0 - 2.3) / 0.25)) } ?? 0
    if over > 0 {
        NSColor.white.withAlphaComponent(0.12 * over).setFill()
        NSBezierPath(roundedRect: tr(NSRect(x: folderCenter.x - 78, y: row - 10, width: 156, height: 146)), xRadius: 14, yRadius: 14).fill()
    }
    iconItem(centerX: appCenter.x, top: row, size: 124, labelY: labelY, label: "Osmotic") { r in appIcon?.draw(in: tr(r)) }
    iconItem(centerX: folderCenter.x, top: row, size: 124, labelY: labelY, label: "Applications") { r in
        folder(NSRect(x: r.minX, y: r.minY + 16, width: r.width, height: r.height - 26))
    }
    iconItem(centerX: dmg.maxX - 130, top: row, size: 124, labelY: labelY, label: "Read Me First.txt") { r in
        document(NSRect(x: r.minX + 18, y: r.minY + 4, width: r.width - 36, height: r.height - 8))
    }

    // The page's own pointer: the drag, as a run of LEDs from the app to the folder. In the clip
    // they light one after another ahead of the icon.
    let dotY = H - row - 62
    var x = win.minX + 226
    var i = 0.0
    while x < win.midX - 62 {
        let lit = t.map { smooth(($0 - 0.7 - i * 0.07) / 0.15) } ?? 1
        amber.withAlphaComponent(0.25 + 0.55 * lit).setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: dotY, width: 7, height: 7)).fill()
        x += 20
        i += 1
    }
    let head = NSBezierPath()
    head.move(to: NSPoint(x: win.midX - 48, y: dotY + 3.5))
    head.line(to: NSPoint(x: win.midX - 62, y: dotY + 13))
    head.line(to: NSPoint(x: win.midX - 62, y: dotY - 6))
    head.close()
    amber.setFill()
    head.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSColor.white.withAlphaComponent(0.1).setStroke()
    let edge = NSBezierPath(roundedRect: tr(win).insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
    edge.stroke()

    guard let t else { return }
    // The hand: in from the corner, onto the icon, press, drag to the folder, let go, step back.
    let grip = NSPoint(x: 10, y: 18)  // where the pointer holds the icon, from its centre
    let startP = NSPoint(x: W - 150, y: H - 60)
    let onApp = NSPoint(x: appCenter.x + grip.x, y: appCenter.y + grip.y)
    let onFolder = NSPoint(x: folderCenter.x + grip.x, y: folderCenter.y + grip.y - 8)
    let away = NSPoint(x: folderCenter.x + 150, y: folderCenter.y + 120)
    func mix(_ a: NSPoint, _ b: NSPoint, _ u: Double) -> NSPoint {
        NSPoint(x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u)
    }
    let hand: NSPoint
    switch t {
    case ..<0.6: hand = mix(startP, onApp, smooth((t - 0.1) / 0.5))
    case ..<0.8: hand = onApp
    case ..<1.75: hand = mix(onApp, onFolder, smooth((t - 0.8) / 0.95))
    case ..<2.2: hand = onFolder
    default: hand = mix(onFolder, away, smooth((t - 2.2) / 0.7))
    }
    // The icon travels with the hand, faded like a drag image, and sinks into the folder on release.
    if t >= 0.72 && t < 2.35 {
        let release = smooth((t - 2.05) / 0.3)
        let size = 112 * (1 - 0.55 * release)
        let c = NSPoint(x: hand.x - grip.x, y: hand.y - grip.y + 6 * release)
        appIcon?.draw(
            in: tr(NSRect(x: c.x - size / 2, y: c.y - size / 2, width: size, height: size)),
            from: .zero, operation: .sourceOver, fraction: 0.62 * (1 - release))
    }
    let pressed = (t >= 0.6 && t < 0.72) || (t >= 2.0 && t < 2.12)
    pointer(tip: hand, scale: pressed ? 0.88 : 1)
}

try save("step-1.png") { step1(nil) }

// The clip: 3.2 s at 30 fps through ffmpeg, H.264 at the still's size. It plays once on the page.
if let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first(where: { FileManager.default.fileExists(atPath: $0) }) {
    let mp4 = images.appendingPathComponent("step-1.mp4")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: ffmpeg)
    p.arguments = [
        "-y", "-v", "error", "-f", "rawvideo", "-pix_fmt", "rgba", "-s", "\(Int(W))x\(Int(H))", "-r", "30", "-i", "-",
        "-an", "-c:v", "libx264", "-preset", "slow", "-crf", "24", "-tune", "animation", "-pix_fmt", "yuv420p",
        "-movflags", "+faststart", mp4.path,
    ]
    let pipe = Pipe()
    p.standardInput = pipe
    try p.run()
    for n in 0..<96 {
        let rep = render { step1(Double(n) / 30) }
        pipe.fileHandleForWriting.write(Data(bytes: rep.bitmapData!, count: Int(W) * Int(H) * 4))
    }
    pipe.fileHandleForWriting.closeFile()
    p.waitUntilExit()
    print(mp4.path)
}

// 2. The first launch: the Settings pane to open, drawn in the system's own visual language.
// The real window can't be captured here (no screen-recording permission), so this is a drawing of
// what the user will see: the layout and colors macOS uses in dark appearance, none of Apple's art.
try save("step-2.png") {
    let win = NSRect(x: 60, y: 92, width: W - 120, height: 336)
    let sidebar: CGFloat = 216
    _ = macWindow(win)
    rgb(43, 43, 46).setFill()  // the sidebar, one step lighter than the content
    NSBezierPath(rect: tr(NSRect(x: win.minX, y: win.minY, width: sidebar, height: win.height))).fill()
    NSColor.white.withAlphaComponent(0.08).setFill()
    NSBezierPath(rect: tr(NSRect(x: win.minX + sidebar, y: win.minY, width: 1, height: win.height))).fill()
    // Window buttons again: the sidebar just covered them, and macOS draws them over it.
    for (i, c) in [rgb(255, 95, 86), rgb(255, 189, 46), rgb(39, 201, 63)].enumerated() {
        c.setFill()
        NSBezierPath(ovalIn: tr(NSRect(x: win.minX + 20 + CGFloat(i) * 22, y: win.minY + 18, width: 14, height: 14))).fill()
    }

    // Sidebar rows: an icon tile and a label, the last one selected.
    let rows = ["General", "Appearance", "Accessibility", "Privacy & Security"]
    for (i, label) in rows.enumerated() {
        let y = win.minY + 74 + CGFloat(i) * 42
        let row = NSRect(x: win.minX + 12, y: y, width: sidebar - 24, height: 34)
        let selected = i == rows.count - 1
        if selected {
            NSGradient(colors: [rgb(10, 132, 255), rgb(0, 112, 235)])!
                .draw(in: NSBezierPath(roundedRect: tr(row), xRadius: 7, yRadius: 7), angle: -90)
        }
        let tile = tr(NSRect(x: row.minX + 9, y: y + 7, width: 20, height: 20))
        (selected ? NSColor.white.withAlphaComponent(0.85) : rgb(120, 120, 126)).setFill()
        NSBezierPath(roundedRect: tile, xRadius: 5, yRadius: 5).fill()
        text(label, sans(16, selected ? .medium : .regular), selected ? .white : rgb(226, 226, 230),
             x: row.minX + 40, y: y + 7, width: row.width - 48)
    }

    // Content: the pane's title, then the two rows of the Security group.
    let cx = win.minX + sidebar + 26
    let cw = win.maxX - cx - 26
    text("Privacy & Security", sans(15, .semibold), rgb(235, 235, 240), x: cx, y: win.minY + 20, width: cw)
    text("Security", sans(14, .semibold), rgb(150, 150, 156), x: cx, y: win.minY + 78, width: cw)
    let box = NSRect(x: cx, y: win.minY + 106, width: cw, height: 148)
    rgb(44, 44, 47).setFill()
    NSBezierPath(roundedRect: tr(box), xRadius: 10, yRadius: 10).fill()
    NSColor.white.withAlphaComponent(0.07).setFill()
    NSBezierPath(rect: tr(NSRect(x: box.minX + 18, y: box.minY + 74, width: box.width - 18, height: 1))).fill()

    let popup = NSRect(x: box.maxX - 254, y: box.minY + 22, width: 236, height: 28)
    text("Allow applications from", sans(15, .regular), rgb(236, 236, 240),
         x: box.minX + 18, y: box.minY + 27, width: popup.minX - box.minX - 30)
    rgb(62, 62, 66).setFill()
    NSBezierPath(roundedRect: tr(popup), xRadius: 7, yRadius: 7).fill()
    text("App Store & Known Developers", sans(13, .regular), rgb(230, 230, 234),
         x: popup.minX + 11, y: popup.minY + 6, width: popup.width - 34)
    text("⌄", sans(14, .semibold), rgb(170, 170, 176), x: popup.maxX - 24, y: popup.minY + 2, width: 16)

    let button = NSRect(x: box.maxX - 164, y: box.minY + 96, width: 146, height: 30)
    text("“Osmotic” was blocked to protect your Mac.", sans(15, .regular), rgb(236, 236, 240),
         x: box.minX + 18, y: box.minY + 101, width: button.minX - box.minX - 34)
    NSGradient(colors: [rgb(10, 132, 255), rgb(0, 112, 235)])!
        .draw(in: NSBezierPath(roundedRect: tr(button), xRadius: 7, yRadius: 7), angle: -90)
    text("Open Anyway", sans(14, .medium), .white, x: button.minX, y: button.minY + 6, width: button.width, align: .center)
    NSGraphicsContext.restoreGraphicsState()

    // The page's own pointer: an amber ring on the one control to press.
    amber.withAlphaComponent(0.9).setStroke()
    let ring = NSBezierPath(roundedRect: tr(button.insetBy(dx: -6, dy: -6)), xRadius: 11, yRadius: 11)
    ring.lineWidth = 2
    ring.stroke()

    NSColor.white.withAlphaComponent(0.1).setStroke()
    let edge = NSBezierPath(roundedRect: tr(win).insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
    edge.stroke()
}

// 3. Connect: the app's own Cameras screen, whole (like the two windows before it), with the page's
// amber ring on the key to press and the pointer on it.
try save("step-3.png") {
    guard let shot = NSImage(contentsOf: images.appendingPathComponent("cameras.png")) else { return }
    // cameras.png is framed already (44-px margin, shadow): place it by its window, 780 px wide.
    let px = shot.representations.first.map { CGFloat($0.pixelsWide) } ?? shot.size.width
    let k: CGFloat = 780 / (px - 88)
    let w = px * k, h = CGFloat(shot.representations.first?.pixelsHigh ?? Int(shot.size.height)) * k
    let origin = NSPoint(x: (W - w) / 2, y: (H - h) / 2)
    shot.draw(in: tr(NSRect(x: origin.x, y: origin.y, width: w, height: h)))
    // The Connect key, from the window's own points (x 809, y 218 under the 32-pt band).
    let ppt = (px - 88) / 1120  // framed pixels per point
    let key = NSPoint(x: origin.x + (44 + 809 * ppt) * k, y: origin.y + (44 + (32 + 218) * ppt) * k)
    amber.withAlphaComponent(0.9).setStroke()
    let ring = NSBezierPath(roundedRect: tr(NSRect(x: key.x - 42, y: key.y - 17, width: 84, height: 34)), xRadius: 8, yRadius: 8)
    ring.lineWidth = 2
    ring.stroke()
    pointer(tip: NSPoint(x: key.x + 14, y: key.y + 6))
}
