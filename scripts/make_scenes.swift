// Procedural "footage" for the screenshots and the demo video: stylised landscapes drawn with Core
// Graphics, so no picture from anyone's camera ever appears (demo mode shows them as thumbnails).
// swift scripts/make_scenes.swift <outdir>   → 10 JPEGs, 1280×720 (same bytes on every run)
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

struct RNG { var s: UInt64; mutating func next() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / Double(1 << 53) } }

func c(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor { CGColor(red: r/255, green: g/255, blue: b/255, alpha: a) }

func gradient(_ ctx: CGContext, _ cols: [CGColor], _ from: CGPoint, _ to: CGPoint, locs: [CGFloat]? = nil) {
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cols as CFArray, locations: locs)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func ridge(_ ctx: CGContext, w: Double, h: Double, base: Double, amp: Double, seed: UInt64, color: CGColor, sharp: Bool = false) {
    var r = RNG(s: seed)
    let f1 = 1 + r.next() * 2, f2 = 3 + r.next() * 4, f3 = 9 + r.next() * 8
    let p1 = r.next() * 6, p2 = r.next() * 6, p3 = r.next() * 6
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 0, y: 0))
    for i in 0...200 {
        let x = Double(i) / 200
        var y = sin(x * f1 * .pi + p1) * 0.5 + sin(x * f2 * .pi + p2) * 0.3 + sin(x * f3 * .pi + p3) * 0.12
        if sharp { y = 1 - abs(y) * 1.6 }
        path.addLine(to: CGPoint(x: x * w, y: (base + amp * y) * h))
    }
    path.addLine(to: CGPoint(x: w, y: 0))
    path.closeSubpath()
    ctx.addPath(path); ctx.setFillColor(color); ctx.fillPath()
}

func sun(_ ctx: CGContext, _ p: CGPoint, _ r: Double, _ core: CGColor, _ glow: CGColor) {
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [glow, glow.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: p, startRadius: 0, endCenter: p, endRadius: r * 5, options: [])
    ctx.setFillColor(core); ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
}

typealias Scene = (CGContext, Double, Double) -> Void

let scenes: [(String, Scene)] = [
    ("sunset-sea", { ctx, w, h in
        gradient(ctx, [c(46, 28, 84), c(196, 72, 88), c(250, 160, 92)], CGPoint(x: 0, y: h), CGPoint(x: 0, y: h * 0.38))
        sun(ctx, CGPoint(x: w * 0.62, y: h * 0.42), h * 0.09, c(255, 226, 170), c(255, 170, 90, 0.55))
        ctx.saveGState(); ctx.clip(to: CGRect(x: 0, y: 0, width: w, height: h * 0.38))
        gradient(ctx, [c(118, 58, 80), c(30, 22, 48)], CGPoint(x: 0, y: h * 0.38), CGPoint(x: 0, y: 0))
        var r = RNG(s: 3)
        for i in 0..<34 {
            let y = h * 0.37 - Double(i) * h * 0.011 * (1 + Double(i) * 0.08)
            let ww = w * (0.05 + r.next() * 0.12) * (1 + Double(i) * 0.05)
            ctx.setFillColor(c(255, 196, 130, 0.55 - Double(i) * 0.014))
            ctx.fill(CGRect(x: w * 0.62 - ww / 2 + (r.next() - 0.5) * 20, y: y, width: ww, height: 1.6 + Double(i) * 0.08))
        }
        ctx.restoreGState()
    }),
    ("alps", { ctx, w, h in
        gradient(ctx, [c(120, 170, 220), c(226, 236, 244)], CGPoint(x: 0, y: h), CGPoint(x: 0, y: h * 0.3))
        ridge(ctx, w: w, h: h, base: 0.58, amp: 0.2, seed: 11, color: c(198, 212, 230), sharp: true)
        ridge(ctx, w: w, h: h, base: 0.46, amp: 0.2, seed: 12, color: c(140, 162, 190), sharp: true)
        ridge(ctx, w: w, h: h, base: 0.32, amp: 0.14, seed: 13, color: c(78, 100, 128), sharp: true)
        ridge(ctx, w: w, h: h, base: 0.16, amp: 0.08, seed: 14, color: c(38, 58, 66))
    }),
    ("dunes", { ctx, w, h in
        gradient(ctx, [c(84, 150, 206), c(236, 214, 180)], CGPoint(x: 0, y: h), CGPoint(x: 0, y: h * 0.45))
        sun(ctx, CGPoint(x: w * 0.2, y: h * 0.8), h * 0.05, c(255, 250, 230), c(255, 240, 200, 0.5))
        ridge(ctx, w: w, h: h, base: 0.46, amp: 0.08, seed: 21, color: c(222, 160, 102))
        ridge(ctx, w: w, h: h, base: 0.34, amp: 0.1, seed: 22, color: c(200, 128, 76))
        ridge(ctx, w: w, h: h, base: 0.2, amp: 0.1, seed: 23, color: c(168, 96, 58))
        ridge(ctx, w: w, h: h, base: 0.08, amp: 0.06, seed: 24, color: c(128, 70, 44))
    }),
    ("city-night", { ctx, w, h in
        gradient(ctx, [c(10, 14, 36), c(40, 44, 96), c(120, 70, 110)], CGPoint(x: 0, y: h), CGPoint(x: 0, y: h * 0.2))
        var r = RNG(s: 31)
        for _ in 0..<60 { ctx.setFillColor(c(255, 255, 255, 0.3 + r.next() * 0.5)); ctx.fill(CGRect(x: r.next() * w, y: h * (0.6 + r.next() * 0.4), width: 1.4, height: 1.4)) }
        var x = -10.0
        while x < w {
            let bw = 26 + r.next() * 50, bh = h * (0.18 + r.next() * 0.45)
            ctx.setFillColor(c(16 + r.next() * 14, 18 + r.next() * 14, 34 + r.next() * 20)); ctx.fill(CGRect(x: x, y: 0, width: bw, height: bh))
            var wy = 8.0
            while wy < bh - 10 {
                var wx = 5.0
                while wx < bw - 7 {
                    if r.next() < 0.36 { ctx.setFillColor(c(255, 200 + r.next() * 40, 120 + r.next() * 60, 0.85)); ctx.fill(CGRect(x: x + wx, y: wy, width: 4, height: 5)) }
                    wx += 8
                }
                wy += 10
            }
            x += bw + 2
        }
    }),
    ("forest-fog", { ctx, w, h in
        gradient(ctx, [c(196, 214, 206), c(236, 238, 228)], CGPoint(x: 0, y: h), CGPoint(x: 0, y: 0))
        var r = RNG(s: 41)
        for layer in 0..<4 {
            let shade = 150 - Double(layer) * 38
            let col = c(shade * 0.55, shade, shade * 0.8)
            let baseY = h * (0.42 - Double(layer) * 0.12)
            var x = -20.0
            while x < w + 20 {
                let th = h * (0.22 + r.next() * 0.16) * (1 + Double(layer) * 0.18), tw = th * 0.36
                let p = CGMutablePath()
                p.move(to: CGPoint(x: x - tw / 2, y: baseY)); p.addLine(to: CGPoint(x: x, y: baseY + th)); p.addLine(to: CGPoint(x: x + tw / 2, y: baseY)); p.closeSubpath()
                ctx.addPath(p); ctx.setFillColor(col); ctx.fillPath()
                x += tw * (0.45 + r.next() * 0.4)
            }
            ctx.setFillColor(col); ctx.fill(CGRect(x: 0, y: 0, width: w, height: baseY))
            gradient(ctx, [c(230, 236, 228, 0.0), c(230, 236, 228, 0.35)], CGPoint(x: 0, y: baseY + h * 0.2), CGPoint(x: 0, y: baseY))
        }
    }),
    ("beach", { ctx, w, h in
        gradient(ctx, [c(40, 130, 210), c(160, 214, 240)], CGPoint(x: 0, y: h), CGPoint(x: 0, y: h * 0.5))
        gradient(ctx, [c(30, 170, 190), c(60, 200, 200)], CGPoint(x: 0, y: h * 0.5), CGPoint(x: 0, y: h * 0.3))
        ctx.setFillColor(c(30, 150, 180)); ctx.fill(CGRect(x: 0, y: h * 0.46, width: w, height: h * 0.04))
        ridge(ctx, w: w, h: h, base: 0.3, amp: 0.03, seed: 51, color: c(250, 250, 245, 0.9))
        ridge(ctx, w: w, h: h, base: 0.28, amp: 0.03, seed: 51, color: c(236, 210, 164))
        gradient(ctx, [c(236, 210, 164, 0), c(200, 170, 120, 0.6)], CGPoint(x: 0, y: h * 0.28), CGPoint(x: 0, y: 0))
    }),
    ("aurora", { ctx, w, h in
        gradient(ctx, [c(4, 10, 28), c(12, 40, 60)], CGPoint(x: 0, y: h), CGPoint(x: 0, y: 0))
        var r = RNG(s: 61)
        for _ in 0..<90 { ctx.setFillColor(c(255, 255, 255, 0.2 + r.next() * 0.6)); ctx.fill(CGRect(x: r.next() * w, y: r.next() * h, width: 1.3, height: 1.3)) }
        for band in 0..<3 {
            for i in 0..<120 {
                let x = Double(i) / 120 * w
                let y = h * (0.55 + 0.12 * sin(Double(i) / 120 * 5 + Double(band)) + Double(band) * 0.06)
                let hh = h * (0.18 + 0.1 * sin(Double(i) * 0.3 + Double(band) * 2))
                let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [c(60, 255, 160, 0.16), c(120, 90, 255, 0)] as CFArray, locations: [0, 1])!
                ctx.saveGState(); ctx.clip(to: CGRect(x: x, y: y, width: w / 120 + 1, height: hh))
                ctx.drawLinearGradient(g, start: CGPoint(x: x, y: y), end: CGPoint(x: x, y: y + hh), options: [])
                ctx.restoreGState()
            }
        }
        ridge(ctx, w: w, h: h, base: 0.14, amp: 0.08, seed: 62, color: c(6, 12, 20))
    }),
    ("road", { ctx, w, h in
        gradient(ctx, [c(246, 170, 110), c(252, 220, 170)], CGPoint(x: 0, y: h), CGPoint(x: 0, y: h * 0.45))
        ridge(ctx, w: w, h: h, base: 0.45, amp: 0.05, seed: 71, color: c(170, 110, 90))
        ctx.setFillColor(c(118, 92, 70)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h * 0.42))
        let p = CGMutablePath()
        p.move(to: CGPoint(x: w * 0.1, y: 0)); p.addLine(to: CGPoint(x: w * 0.495, y: h * 0.42)); p.addLine(to: CGPoint(x: w * 0.505, y: h * 0.42)); p.addLine(to: CGPoint(x: w * 0.9, y: 0)); p.closeSubpath()
        ctx.addPath(p); ctx.setFillColor(c(52, 50, 56)); ctx.fillPath()
        for i in 0..<9 {
            let t0 = pow(Double(i) / 9, 1.8), t1 = pow((Double(i) + 0.45) / 9, 1.8)
            let y0 = h * 0.42 * (1 - t1), y1 = h * 0.42 * (1 - t0)
            let w0 = 0.004 + 0.02 * t1, w1 = 0.004 + 0.02 * t0
            let q = CGMutablePath()
            q.move(to: CGPoint(x: w * (0.5 - w0), y: y0)); q.addLine(to: CGPoint(x: w * (0.5 - w1), y: y1)); q.addLine(to: CGPoint(x: w * (0.5 + w1), y: y1)); q.addLine(to: CGPoint(x: w * (0.5 + w0), y: y0)); q.closeSubpath()
            ctx.addPath(q); ctx.setFillColor(c(250, 220, 120)); ctx.fillPath()
        }
    }),
    ("lake-dawn", { ctx, w, h in
        gradient(ctx, [c(150, 160, 210), c(250, 196, 180)], CGPoint(x: 0, y: h), CGPoint(x: 0, y: h * 0.45))
        ridge(ctx, w: w, h: h, base: 0.5, amp: 0.1, seed: 81, color: c(110, 110, 150))
        ridge(ctx, w: w, h: h, base: 0.46, amp: 0.05, seed: 82, color: c(70, 76, 110))
        ctx.saveGState(); ctx.clip(to: CGRect(x: 0, y: 0, width: w, height: h * 0.44))
        gradient(ctx, [c(240, 190, 180), c(120, 130, 180)], CGPoint(x: 0, y: h * 0.44), CGPoint(x: 0, y: 0))
        ctx.restoreGState()
        ctx.setFillColor(c(255, 255, 255, 0.25)); ctx.fill(CGRect(x: 0, y: h * 0.43, width: w, height: 1))
    }),
    ("canyon", { ctx, w, h in
        gradient(ctx, [c(70, 140, 210), c(200, 220, 236)], CGPoint(x: 0, y: h), CGPoint(x: 0, y: h * 0.5))
        ridge(ctx, w: w, h: h, base: 0.55, amp: 0.06, seed: 91, color: c(212, 120, 76))
        ridge(ctx, w: w, h: h, base: 0.42, amp: 0.08, seed: 92, color: c(186, 92, 58))
        ridge(ctx, w: w, h: h, base: 0.26, amp: 0.1, seed: 93, color: c(146, 66, 44))
        ridge(ctx, w: w, h: h, base: 0.1, amp: 0.06, seed: 94, color: c(96, 44, 34))
    }),
    ("snow-field", { ctx, w, h in
        gradient(ctx, [c(96, 150, 216), c(214, 230, 246)], CGPoint(x: 0, y: h), CGPoint(x: 0, y: h * 0.4))
        sun(ctx, CGPoint(x: w * 0.8, y: h * 0.78), h * 0.04, c(255, 255, 250), c(255, 255, 240, 0.6))
        ridge(ctx, w: w, h: h, base: 0.48, amp: 0.16, seed: 101, color: c(232, 240, 250), sharp: true)
        ridge(ctx, w: w, h: h, base: 0.3, amp: 0.06, seed: 102, color: c(248, 250, 255))
        ridge(ctx, w: w, h: h, base: 0.16, amp: 0.05, seed: 103, color: c(220, 230, 244))
    }),
    ("concert", { ctx, w, h in
        ctx.setFillColor(c(8, 6, 16)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let cols = [c(255, 60, 140, 0.35), c(80, 120, 255, 0.35), c(255, 180, 40, 0.3), c(60, 240, 220, 0.3)]
        for (i, col) in cols.enumerated() {
            let x = w * (0.15 + Double(i) * 0.23)
            let p = CGMutablePath()
            p.move(to: CGPoint(x: x, y: h)); p.addLine(to: CGPoint(x: x - w * 0.18 + Double(i) * 30, y: 0)); p.addLine(to: CGPoint(x: x + w * 0.02 + Double(i) * 30, y: 0)); p.closeSubpath()
            ctx.addPath(p); ctx.setFillColor(col); ctx.fillPath()
        }
        var r = RNG(s: 111)
        for _ in 0..<70 {
            let x = r.next() * w, y = h * 0.02 + r.next() * h * 0.12, rr = 10 + r.next() * 12
            ctx.setFillColor(c(4, 4, 8)); ctx.fillEllipse(in: CGRect(x: x - rr, y: y, width: rr * 2, height: rr * 2.4))
        }
        ctx.setFillColor(c(4, 4, 8)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h * 0.08))
    }),
]

func render(_ name: String, _ scene: Scene, w: Int, h: Int) {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    scene(ctx, Double(w), Double(h))
    // A soft vignette, like a real lens.
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [c(0, 0, 0, 0), c(0, 0, 0, 0.28)] as CFArray, locations: [0.55, 1])!
    let ctr = CGPoint(x: w / 2, y: h / 2)
    ctx.drawRadialGradient(g, startCenter: ctr, startRadius: 0, endCenter: ctr, endRadius: Double(max(w, h)) * 0.72, options: [.drawsAfterEndLocation])
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .jpeg, properties: [.compressionFactor: 0.88])!.write(to: URL(fileURLWithPath: "\(out)/\(name).jpg"))
}

for (i, (name, scene)) in scenes.enumerated() {
    render(String(format: "%02d-%@", i, name), scene, w: 1280, h: 720)
}
