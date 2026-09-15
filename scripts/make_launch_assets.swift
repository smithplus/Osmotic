// Product Hunt gallery (1270×760, rendered at 2x) and the 240×240 thumbnail, from the README
// screenshots and the icon. Copy lives in docs/LAUNCH.md; keep the two in step.
// Run: swift scripts/make_icon.swift . && swift scripts/make_launch_assets.swift .   → build/launch/*.png
// Slides 3 and 5 use the raw renders of make_shots.swift and make_demo_video.swift (build/), so run those first.
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let out = root.appendingPathComponent("build/launch")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let images = root.appendingPathComponent("docs/images")

let scale: CGFloat = 2
let W: CGFloat = 1270, H: CGFloat = 760

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}
let ink = rgb(232, 229, 222), muted = rgb(160, 157, 150), amber = rgb(255, 146, 52), accent = rgb(238, 92, 36)
let green = rgb(74, 222, 128)

func mono(_ size: CGFloat, _ weight: NSFont.Weight = .medium) -> NSFont { .monospacedSystemFont(ofSize: size, weight: weight) }
func sans(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont { .systemFont(ofSize: size, weight: weight) }

/// Draws text in a box (top-left origin in slide points); returns the height used.
@discardableResult
func text(_ s: String, _ font: NSFont, _ color: NSColor, x: CGFloat, y: CGFloat, width: CGFloat,
          tracking: CGFloat = 0, align: NSTextAlignment = .left, line: CGFloat = 1.1, glow: NSColor? = nil) -> CGFloat {
    let p = NSMutableParagraphStyle()
    p.alignment = align
    p.lineHeightMultiple = line
    var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: p, .kern: tracking]
    if let glow {
        let sh = NSShadow(); sh.shadowColor = glow; sh.shadowBlurRadius = 8; sh.shadowOffset = .zero
        attrs[.shadow] = sh
    }
    let str = NSAttributedString(string: s, attributes: attrs)
    let h = ceil(str.boundingRect(with: NSSize(width: width, height: 2000), options: [.usesLineFragmentOrigin]).height)
    str.draw(with: NSRect(x: x, y: H - y - h, width: width, height: h), options: [.usesLineFragmentOrigin])
    return h
}

func plate() {
    NSGradient(colors: [rgb(38, 38, 37), rgb(27, 27, 26)])!.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.05), NSColor.white.withAlphaComponent(0)])!
        .draw(fromCenter: NSPoint(x: W * 0.5, y: H), radius: 0, toCenter: NSPoint(x: W * 0.5, y: H), radius: W * 0.7, options: [])
}

func wordmark(x: CGFloat = 48, y: CGFloat = 40) {
    // "osmotic." with the dot on the baseline, as in the app.
    let font = sans(22, .heavy)
    let str = NSAttributedString(string: "osmotic", attributes: [.font: font, .foregroundColor: ink, .kern: -0.4])
    let size = str.size()
    let origin = NSPoint(x: x, y: H - y - size.height)  // bottom-left of the line box
    str.draw(at: origin)
    let baseline = origin.y - font.descender  // descender is negative
    accent.setFill()
    NSBezierPath(ovalIn: NSRect(x: x + size.width + 2, y: baseline, width: 6, height: 6)).fill()
}

func lcd(_ rect: NSRect, radius: CGFloat = 14) {
    let r = NSRect(x: rect.minX, y: H - rect.maxY, width: rect.width, height: rect.height)
    rgb(16, 16, 15).setFill()
    NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).addClip()
    NSGradient(colors: [NSColor.black.withAlphaComponent(0.6), NSColor.black.withAlphaComponent(0)])!
        .draw(in: NSRect(x: r.minX, y: r.maxY - 8, width: r.width, height: 8), angle: -90)
    NSGraphicsContext.restoreGraphicsState()
}

func panel(_ rect: NSRect, screws: Bool = true) {
    let r = NSRect(x: rect.minX, y: H - rect.maxY, width: rect.width, height: rect.height)
    let path = NSBezierPath(roundedRect: r, xRadius: 14, yRadius: 14)
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.3); sh.shadowBlurRadius = 14; sh.shadowOffset = NSSize(width: 0, height: -6)
    sh.set()
    NSGradient(colors: [rgb(47, 47, 46), rgb(40, 40, 39)])!.draw(in: path, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    NSColor.white.withAlphaComponent(0.09).setStroke()
    let top = NSBezierPath(); top.move(to: NSPoint(x: r.minX + 14, y: r.maxY - 0.5)); top.line(to: NSPoint(x: r.maxX - 14, y: r.maxY - 0.5)); top.stroke()
    if screws {
        for (sx, sy) in [(r.minX + 12, r.minY + 12), (r.maxX - 12, r.minY + 12), (r.minX + 12, r.maxY - 12), (r.maxX - 12, r.maxY - 12)] {
            rgb(20, 20, 19).setFill(); NSBezierPath(ovalIn: NSRect(x: sx - 2.5, y: sy - 2.5, width: 5, height: 5)).fill()
        }
    }
}

func led(x: CGFloat, y: CGFloat, d: CGFloat = 14) {
    let r = NSRect(x: x - d / 2, y: H - y - d / 2, width: d, height: d)
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = green.withAlphaComponent(0.6); sh.shadowBlurRadius = 8; sh.shadowOffset = .zero; sh.set()
    green.setFill(); NSBezierPath(ovalIn: r).fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [rgb(200, 247, 218), green, rgb(29, 122, 65)], atLocations: [0, 0.45, 1], colorSpace: .sRGB)!
        .draw(in: NSBezierPath(ovalIn: r), relativeCenterPosition: NSPoint(x: -0.3, y: 0.3))
}

/// A README screenshot (already framed with shadow and padding), placed by its visible window rect.
func shot(_ name: String, x: CGFloat, y: CGFloat, width: CGFloat) {
    guard let img = NSImage(contentsOf: images.appendingPathComponent(name)) else { return }
    let px = img.representations.first.map { CGFloat($0.pixelsWide) } ?? img.size.width
    let pad = 44 / px * width  // frame.swift pads 44 px on each side
    let w = width + pad * 2
    let h = w * img.size.height / img.size.width
    img.draw(in: NSRect(x: x - pad, y: H - y - h + pad, width: w, height: h))
}

func slide(_ name: String, _ draw: () -> Void) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    plate()
    draw()
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
    print(out.appendingPathComponent(name).path)
}

func label(_ s: String, x: CGFloat, y: CGFloat) {
    text(s.uppercased(), mono(13, .medium), amber, x: x, y: y, width: 500, tracking: 2, glow: amber.withAlphaComponent(0.35))
}

// 1. Hero
try slide("01-hero.png") {
    wordmark()
    let lw: CGFloat = 470
    label("Osmo › Mac · Wireless", x: 48, y: 150)
    let h = text("Download your DJI Osmo footage to your Mac over Wi-Fi", sans(46, .bold), ink, x: 48, y: 182, width: lw, tracking: -1.2, line: 1.02)
    text("No cable, no card reader, no phone in between. Free and open source.", sans(19, .regular), muted, x: 48, y: 182 + h + 22, width: lw - 30, line: 1.25)
    shot("library.png", x: 560, y: 110, width: 760)
}

// 2. How it works
try slide("02-how-it-works.png") {
    wordmark()
    label("How it works", x: 48, y: 140)
    text("Your Mac talks to the camera directly", sans(46, .bold), ink, x: 48, y: 170, width: 1100, tracking: -1.2)
    text("DJI's own app sends wireless transfers to a phone only. Osmotic brings them to your Mac.", sans(19, .regular), muted, x: 48, y: 236, width: 1100)
    panel(NSRect(x: 48, y: 330, width: W - 96, height: 250))
    let stages = [("Bluetooth", "The Mac finds the camera and pairs with it. You approve once, on the camera."),
                  ("Wi-Fi", "The camera hands over its Wi-Fi password and the Mac joins its network."),
                  ("Download", "New files land in a folder per day, dated when they were shot. About 33 MB/s."),
                  ("Back home", "When you disconnect, your Mac rejoins your Wi-Fi.")]
    let colW = (W - 96 - 64) / 4
    for (i, s) in stages.enumerated() {
        let cx = 48 + 32 + colW * CGFloat(i)
        led(x: cx + colW / 2, y: 385)
        text(s.0.uppercased(), sans(14, .semibold), ink, x: cx, y: 412, width: colW, tracking: 2.2, align: .center)
        text(s.1, sans(17, .regular), muted, x: cx + 12, y: 450, width: colW - 24, align: .center, line: 1.25)
    }
}

/// The top of a window, wide: the app's own 2x render (demo mode), cut below its content, with the
/// title band and buttons on top, rounded, with the shots' shadow. For screens whose content sits
/// at the top (connecting, webcam), so they read large instead of as a mostly empty window.
func windowTop(_ raw: URL, points: CGFloat, x: CGFloat, y: CGFloat, width: CGFloat) {
    guard let img = NSImage(contentsOf: raw)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
        let crop = img.cropping(to: CGRect(x: 0, y: 0, width: img.width, height: Int(points * 2)))
    else { print("missing \(raw.path): run make_shots.swift and make_demo_video.swift first"); return }
    let k = width / 1120  // slide points per window point
    let band = 32 * k
    let rect = NSRect(x: x, y: H - y - band - points * k, width: width, height: band + points * k)
    let path = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.45); sh.shadowBlurRadius = 30
    sh.shadowOffset = NSSize(width: 0, height: -12); sh.set()
    rgb(34, 34, 33).setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSImage(cgImage: crop, size: NSSize(width: width, height: points * k))
        .draw(in: NSRect(x: x, y: rect.minY, width: width, height: points * k))
    let plate = NSBitmapImageRep(cgImage: crop).colorAt(x: crop.width / 2, y: 2) ?? rgb(34, 34, 33)
    plate.setFill()
    NSBezierPath(rect: NSRect(x: x, y: rect.maxY - band, width: width, height: band)).fill()
    for (i, c) in [rgb(255, 95, 87), rgb(254, 188, 46), rgb(40, 200, 64)].enumerated() {
        c.setFill()
        let d = 12 * k
        NSBezierPath(ovalIn: NSRect(x: x + (10 + 23 * CGFloat(i)) * k, y: rect.maxY - band / 2 - d / 2, width: d, height: d)).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    NSColor.white.withAlphaComponent(0.1).setStroke()
    NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12).stroke()
}

// 3. Connect: the five lights, mid-connection, large.
try slide("03-connect.png") {
    wordmark()
    label("Connect", x: 48, y: 130)
    text("One click to connect", sans(46, .bold), ink, x: 48, y: 160, width: 1100, tracking: -1.2)
    text("Five lights show where it is. Only new files come down, and a download that stops picks up where it left off.",
         sans(19, .regular), muted, x: 48, y: 226, width: 1100)
    windowTop(root.appendingPathComponent("build/video/raw/c-wifi.png"), points: 340, x: 48, y: 292, width: W - 96)
}

// 4. Live
try slide("04-live.png") {
    wordmark()
    label("Tab: Live", x: 48, y: 150)
    let h = text("Record and switch modes from across the room", sans(44, .bold), ink, x: 48, y: 182, width: 450, tracking: -1.1, line: 1.02)
    text("Start and stop recording, take photos, switch Video, Photo, Slow-mo and Low Light, and watch the camera live over Wi-Fi.",
         sans(19, .regular), muted, x: 48, y: 182 + h + 22, width: 430, line: 1.25)
    shot("live.png", x: 540, y: 110, width: 700)
}

// 5. Webcam: the three steps, large.
try slide("05-webcam.png") {
    wordmark()
    label("Tab: Webcam", x: 48, y: 130)
    text("A USB webcam with a gimbal", sans(46, .bold), ink, x: 48, y: 160, width: 1100, tracking: -1.2)
    text("Plug the camera in with USB-C and choose Webcam. Zoom, Meet, FaceTime and OBS see it, even with Osmotic closed.",
         sans(19, .regular), muted, x: 48, y: 226, width: 1100)
    windowTop(root.appendingPathComponent("build/shots/webcam-raw.png"), points: 340, x: 48, y: 292, width: W - 96)
}

// 6. Comparison
try slide("06-compare.png") {
    wordmark()
    label("How it compares", x: 48, y: 140)
    text("The missing path from camera to Mac", sans(46, .bold), ink, x: 48, y: 170, width: 1100, tracking: -1.2)
    lcd(NSRect(x: 48, y: 260, width: W - 96, height: 380))
    let cols: [CGFloat] = [80, 400, 600, 800, 1000]
    let head = ["", "Osmotic", "DJI Mimo", "Cable or reader", "Pro offload apps"]
    for (i, s) in head.enumerated() {
        text(s.uppercased(), mono(12), NSColor(srgbRed: 236 / 255, green: 228 / 255, blue: 214 / 255, alpha: 0.55),
             x: cols[i], y: 292, width: 190, tracking: 1.6)
    }
    let rows = [["Camera to Mac, wireless", "Yes", "Phone only", "No", "No"],
                ["Price", "Free", "Free", "A reader", "From $169"],
                ["Open source", "Yes", "No", "n/a", "No"],
                ["Knows Osmo files", "Yes", "Yes", "No", "No"],
                ["Made for", "Osmo on a Mac", "Phone editing", "Any camera", "Film crews"]]
    for (r, row) in rows.enumerated() {
        let y = 340 + CGFloat(r) * 56
        for (i, s) in row.enumerated() {
            let color = i == 1 ? green : (i == 0 ? amber : amber.withAlphaComponent(0.72))
            text(s.uppercased(), mono(15), color, x: cols[i], y: y, width: i == 0 ? 310 : 190, tracking: 1.5,
                 glow: (i == 1 ? green : amber).withAlphaComponent(0.3))
        }
    }
    text("Pro offload apps: OffShoot and ShotPut Pro (their sites, Sept 2026). DJI Mimo: per DJI's export guide.",
         sans(13, .regular), muted, x: 48, y: 660, width: 1100)
}

// 7. Open and private
try slide("07-open.png") {
    wordmark()
    label("Free · MIT · No account", x: 48, y: 140)
    text("Open source, and nothing leaves your Mac", sans(46, .bold), ink, x: 48, y: 170, width: 1100, tracking: -1.2)
    panel(NSRect(x: 48, y: 290, width: W - 96, height: 360))
    text("Made by smithplus", sans(22, .semibold), ink, x: 90, y: 330, width: 1000)
    text("Built on Osmosis by Konrad Iturbe and Kaze for DJI by Brian Merchant, with years of protocol research by the DJI OGs and others.",
         sans(19, .regular), muted, x: 90, y: 372, width: 1080, line: 1.3)
    text("No analytics. No account. Updates come from GitHub and install only if their signature checks out.",
         sans(19, .regular), ink, x: 90, y: 520, width: 1080, line: 1.3)
    text("github.com/smithplus/Osmotic", mono(15), amber, x: 90, y: 590, width: 600, tracking: 1, glow: amber.withAlphaComponent(0.3))
}

// Social card for the landing page (og:image, 1200×630). Link previews show it at about a third of
// this width, so the headline is huge and says what the app is for; a reader who only sees the card
// should not guess "music player". Drawn on its own canvas, not by scaling a gallery slide.
do {
    let cw: CGFloat = 1200, ch: CGFloat = 630
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(cw), pixelsHigh: Int(ch), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    NSGradient(colors: [rgb(38, 38, 37), rgb(25, 25, 24)])!.draw(in: NSRect(x: 0, y: 0, width: cw, height: ch), angle: -90)

    /// Text from the top-left of this canvas.
    @discardableResult
    func card(_ str: String, _ font: NSFont, _ color: NSColor, x: CGFloat, y: CGFloat, width: CGFloat,
              tracking: CGFloat = 0, line: CGFloat = 1.0, glow: NSColor? = nil) -> CGFloat {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = line
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: p, .kern: tracking]
        if let glow {
            let sh = NSShadow(); sh.shadowColor = glow; sh.shadowBlurRadius = 10; sh.shadowOffset = .zero
            attrs[.shadow] = sh
        }
        let a = NSAttributedString(string: str, attributes: attrs)
        let h = ceil(a.boundingRect(with: NSSize(width: width, height: 900), options: [.usesLineFragmentOrigin]).height)
        a.draw(with: NSRect(x: x, y: ch - y - h, width: width, height: h), options: [.usesLineFragmentOrigin])
        return h
    }

    // The app's screenshot, cropped to the grid of clips: footage, at a glance.
    if let shot = NSImage(contentsOf: images.appendingPathComponent("library.png")),
        let cg = shot.cgImage(forProposedRect: nil, context: nil, hints: nil)
    {
        let cropW = Int(Double(cg.width) * 0.62), cropH = Int(Double(cg.height) * 0.42)
        if let crop = cg.cropping(to: CGRect(x: cg.width - cropW - 60, y: Int(Double(cg.height) * 0.30), width: cropW, height: cropH)) {
            let w: CGFloat = 470, h = w * CGFloat(cropH) / CGFloat(cropW)
            let r = NSRect(x: cw - w - 56, y: (ch - h) / 2, width: w, height: h)
            NSGraphicsContext.saveGraphicsState()
            let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.5); sh.shadowBlurRadius = 30; sh.shadowOffset = NSSize(width: 0, height: -10)
            sh.set()
            let clip = NSBezierPath(roundedRect: r, xRadius: 14, yRadius: 14)
            clip.addClip()
            NSImage(cgImage: crop, size: r.size).draw(in: r)
            // The crop cuts a column: fade that edge so it reads as "there is more".
            NSGradient(colors: [rgb(28, 28, 27), rgb(28, 28, 27, 0)])!
                .draw(in: NSRect(x: r.minX, y: r.minY, width: 90, height: r.height), angle: 0)
            NSGraphicsContext.restoreGraphicsState()
            NSColor.white.withAlphaComponent(0.1).setStroke()
            NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14).stroke()
        }
    }

    // Wordmark, then the headline: what it does, in as few words as read at thumbnail size.
    let font = sans(30, .heavy)
    let mark = NSAttributedString(string: "osmotic", attributes: [.font: font, .foregroundColor: ink, .kern: -0.6])
    mark.draw(at: NSPoint(x: 64, y: ch - 64 - mark.size().height))
    accent.setFill()
    NSBezierPath(ovalIn: NSRect(x: 64 + mark.size().width + 3, y: ch - 64 - mark.size().height - font.descender, width: 8, height: 8)).fill()

    card("DJI OSMO → MAC", mono(23, .medium), amber, x: 64, y: 190, width: 620, tracking: 3.5, glow: amber.withAlphaComponent(0.35))
    let hh = card("Camera footage,\nstraight to\nyour Mac.", sans(78, .bold), ink, x: 64, y: 232, width: 620, tracking: -2.2, line: 1.02)
    card("Wireless, over the camera's own Wi-Fi.\nFree Mac app.", sans(26, .regular), muted, x: 64, y: 232 + hh + 26, width: 600, line: 1.25)

    NSGraphicsContext.restoreGraphicsState()
    // JPEG: link previews (WhatsApp, iMessage) often skip cards over ~300 KB.
    try rep.representation(using: .jpeg, properties: [.compressionFactor: 0.84])!.write(to: images.appendingPathComponent("og.jpg"))
    print(images.appendingPathComponent("og.jpg").path)
}

// Thumbnail: the icon at 240×240.
if let icon = NSImage(contentsOf: root.appendingPathComponent("build/icon-1024.png")) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 240, pixelsHigh: 240, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    icon.draw(in: NSRect(x: 0, y: 0, width: 240, height: 240))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("thumbnail-240.png"))
    print(out.appendingPathComponent("thumbnail-240.png").path)
}
