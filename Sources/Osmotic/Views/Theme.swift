import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Design tokens for Osmotic as a physical object: an anodised aluminium faceplate, injection-moulded
/// plastic keys, a black glass LCD and lens LEDs. One light source, from above: every raised part has
/// a lit top edge and a contact shadow below; every recessed part has its shadow inside, at the top.
/// Type is silkscreen — small, printed, dark grey on metal — and amber on the LCD.
enum Theme {
    private static func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> Color {
        Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: a)
    }

    // Aluminium
    static let metalTop = rgb(222, 221, 217)
    static let metalBottom = rgb(203, 202, 197)
    static let metalEdgeLight = Color.white.opacity(0.75)
    static let metalEdgeDark = rgb(0, 0, 0, 0.16)
    // Recess (a milled pocket in the plate)
    static let recess = rgb(193, 192, 187)
    // Silkscreen ink
    static let ink = rgb(44, 43, 41)
    static let muted = rgb(104, 102, 97)
    static let hairline = rgb(0, 0, 0, 0.12)
    // Plastics
    static let accent = rgb(238, 92, 36)            // orange key
    static let accentTop = rgb(247, 114, 60)
    static let accentBottom = rgb(214, 74, 22)
    static let charcoalTop = rgb(62, 61, 59)
    static let charcoalBottom = rgb(34, 34, 33)
    static let greyTop = rgb(240, 239, 235)
    static let greyBottom = rgb(214, 212, 207)
    // LCD
    static let lcd = rgb(19, 20, 18)
    static let lcdText = rgb(255, 146, 52)
    static let lcdDim = rgb(255, 146, 52, 0.10)
    // Signals
    static let success = rgb(74, 190, 88)
    static let warning = rgb(255, 176, 32)
    static let danger = rgb(232, 56, 42)

    // Legacy names still used by a few views
    static var window: Color { metalBottom }
    static var surface: Color { metalTop }
    static var well: Color { recess }

    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 16
    static let s4: CGFloat = 24
    static let s5: CGFloat = 32
    static let s6: CGFloat = 48

    static let radiusS: CGFloat = 5
    static let radiusM: CGFloat = 9
    static let radiusL: CGFloat = 14

    /// Printed wordmark / headings on metal.
    static func display(_ size: CGFloat = 26) -> Font { .system(size: size, weight: .bold, design: .default) }
    /// Silkscreen: small caps sans.
    static func label(_ size: CGFloat = 9.5) -> Font { .system(size: size, weight: .semibold, design: .default) }
    /// LCD / numeric readouts.
    static func readout(_ size: CGFloat = 13, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Materials

/// Brushed aluminium grain, generated once: horizontal-streaked noise, tiled at low opacity over the
/// plate's gradient.
enum BrushedMetal {
    static let grain: Image = {
        let size: CGFloat = 640
        let blur: CGFloat = 36
        let noise = CIFilter.randomGenerator().outputImage!
            .cropped(to: CGRect(x: 0, y: 0, width: size + blur * 4, height: size))
        let mono = noise.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0, kCIInputContrastKey: 1.6, kCIInputBrightnessKey: 0,
        ])
        let streaked = mono.applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: blur, kCIInputAngleKey: 0])
            .cropped(to: CGRect(x: blur * 2, y: 0, width: size, height: size))
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(streaked, from: streaked.extent) else { return Image(systemName: "square") }
        return Image(decorative: cg, scale: 2)
    }()
}

/// The faceplate: warm silver gradient + brushed grain.
struct AluminumPlate: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.metalTop, Theme.metalBottom], startPoint: .top, endPoint: .bottom)
            BrushedMetal.grain
                .resizable(resizingMode: .tile)
                .opacity(0.24)
                .blendMode(.overlay)
        }
    }
}

extension View {
    /// A raised module milled from the plate: lit top edge, contact shadow.
    func raisedPanel(radius: CGFloat = Theme.radiusL) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            .background {
                shape.fill(LinearGradient(colors: [Theme.metalTop, Theme.metalBottom.opacity(0.96)],
                                          startPoint: .top, endPoint: .bottom))
                    .overlay { BrushedMetal.grain.resizable(resizingMode: .tile).opacity(0.14).blendMode(.overlay).clipShape(shape) }
            }
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [Theme.metalEdgeLight, Theme.metalEdgeDark],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.14), radius: 1, y: 1)
            .shadow(color: .black.opacity(0.10), radius: 10, y: 6)
    }

    /// A pocket milled into the plate: shadow inside at the top, a lit lip at the bottom.
    func recessed(radius: CGFloat = Theme.radiusM) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            .background {
                shape.fill(Theme.recess.shadow(.inner(color: .black.opacity(0.28), radius: 3, y: 2)))
            }
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [.black.opacity(0.14), .white.opacity(0.55)],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
    }

    /// Back-compat for views that still ask for a card.
    func card(padding: CGFloat = Theme.s3) -> some View { self.padding(padding).raisedPanel() }
}

/// Black glass display: bezel, inner shadow, a faint diagonal glare.
struct LCDGlass<Content: View>: View {
    var radius: CGFloat = Theme.radiusM
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                shape.fill(Theme.lcd.shadow(.inner(color: .black.opacity(0.85), radius: 4, y: 2)))
            }
            .overlay {
                shape.fill(LinearGradient(stops: [
                    .init(color: .white.opacity(0.07), location: 0),
                    .init(color: .white.opacity(0.0), location: 0.45),
                ], startPoint: .topLeading, endPoint: .bottomTrailing))
                .allowsHitTesting(false)
            }
            .overlay { shape.strokeBorder(Color.black.opacity(0.55), lineWidth: 1) }
            .padding(3)
            .background {
                // The bezel the glass sits in.
                RoundedRectangle(cornerRadius: radius + 3, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.charcoalTop, Theme.charcoalBottom], startPoint: .top, endPoint: .bottom))
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius + 3, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.18), .black.opacity(0.4)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
    }
}

/// Amber LCD text with the unlit segments faintly behind it, like a real segment display.
struct LCDText: View {
    let text: String
    var size: CGFloat = 13
    var weight: Font.Weight = .semibold
    var color: Color = Theme.lcdText
    /// Width, in characters, of the ghost segments behind the value.
    var ghost: Int? = nil

    var body: some View {
        ZStack(alignment: .leading) {
            if let ghost {
                Text(String(repeating: "8", count: ghost))
                    .foregroundStyle(Theme.lcdDim)
            }
            Text(text)
                .foregroundStyle(color)
                .shadow(color: color.opacity(0.55), radius: 3)
        }
        .font(.system(size: size, weight: weight, design: .monospaced))
        .lineLimit(1)
    }
}

// MARK: - Controls

/// Silkscreen label printed on the metal.
struct Silk: View {
    let text: String
    var color: Color = Theme.muted
    var size: CGFloat = 9.5

    init(_ text: String, color: Color = Theme.muted, size: CGFloat = 9.5) {
        self.text = text
        self.color = color
        self.size = size
    }

    var body: some View {
        Text(text.uppercased())
            .font(Theme.label(size))
            .tracking(0.9)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

/// A lens LED: coloured dome with a specular dot; lit ones throw a little light.
struct LED: View {
    enum State { case off, on, blink }
    var color: Color = Theme.accent
    var state: State = .on
    var label: String? = nil
    var size: CGFloat = 8
    @SwiftUI.State private var phase = false

    var body: some View {
        HStack(spacing: 7) {
            // A blinking LED pulses its brightness; it never reads as switched off.
            let lit = state != .off
            ZStack {
                Circle().fill(Color.black.opacity(0.45)).frame(width: size + 3, height: size + 3)   // bezel hole
                Circle()
                    .fill(RadialGradient(colors: lit ? [color.opacity(1), color.opacity(0.75), color.opacity(0.45)]
                                                     : [Color(white: 0.30), Color(white: 0.18)],
                                         center: .init(x: 0.4, y: 0.35), startRadius: 0, endRadius: size * 0.7))
                    .frame(width: size, height: size)
                    .opacity(state == .blink && phase ? 0.45 : 1)
                Circle().fill(.white.opacity(lit ? 0.85 : 0.35))
                    .frame(width: size * 0.28, height: size * 0.28)
                    .offset(x: -size * 0.16, y: -size * 0.18)
            }
            .shadow(color: lit ? color.opacity(state == .blink && phase ? 0.2 : 0.7) : .clear, radius: 4)
            .animation(state == .blink ? .easeInOut(duration: 0.6).repeatForever() : .default, value: phase)
            .onAppear { if state == .blink { phase = true } }
            if let label { Silk(label, color: Theme.ink) }
        }
    }
}

/// Section header printed on the plate: `01 CERCA` with a thin engraved rule.
struct SectionIndex: View {
    let number: Int
    let title: String
    var trailing: AnyView? = nil

    var body: some View {
        HStack(spacing: Theme.s2) {
            Text(String(format: "%02d", number))
                .font(Theme.readout(10, weight: .bold))
                .foregroundStyle(Theme.accent)
            Silk(title, color: Theme.ink, size: 10)
            EngravedRule()
            if let trailing { trailing }
        }
    }
}

/// A line cut into the metal: dark over light.
struct EngravedRule: View {
    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(.black.opacity(0.13)).frame(height: 1)
            Rectangle().fill(.white.opacity(0.55)).frame(height: 1)
        }
    }
}

/// A physical plastic key. Pressing sinks it and shortens its shadow.
struct KeyButtonStyle: ButtonStyle {
    enum Kind { case ink, signal, ghost }
    var kind: Kind = .ghost
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let (top, bottom, text): (Color, Color, Color) = switch kind {
        case .signal: (Theme.accentTop, Theme.accentBottom, .white)
        case .ink: (Theme.charcoalTop, Theme.charcoalBottom, Color(white: 0.93))
        case .ghost: (Theme.greyTop, Theme.greyBottom, Theme.ink)
        }
        let shape = RoundedRectangle(cornerRadius: compact ? 6 : 8, style: .continuous)
        return configuration.label
            .font(.system(size: compact ? 10 : 11, weight: .bold))
            .tracking(0.7)
            .textCase(.uppercase)
            .foregroundStyle(text)
            .padding(.horizontal, compact ? 11 : 16)
            .frame(minHeight: compact ? 26 : 34)
            .background {
                shape.fill(LinearGradient(colors: pressed ? [bottom, top] : [top, bottom], startPoint: .top, endPoint: .bottom))
            }
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(kind == .ghost ? 0.9 : 0.35), .black.opacity(0.25)],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
            .shadow(color: .black.opacity(pressed ? 0.25 : 0.32), radius: pressed ? 0.5 : 1.2, y: pressed ? 0.5 : 1.6)
            .shadow(color: .black.opacity(pressed ? 0.05 : 0.12), radius: pressed ? 2 : 6, y: pressed ? 1 : 4)
            .offset(y: pressed ? 1 : 0)
            .animation(.snappy(duration: 0.08), value: pressed)
    }
}

extension ButtonStyle where Self == KeyButtonStyle {
    static var key: KeyButtonStyle { KeyButtonStyle(kind: .ink) }
    static var signalKey: KeyButtonStyle { KeyButtonStyle(kind: .signal) }
    static var ghostKey: KeyButtonStyle { KeyButtonStyle(kind: .ghost, compact: true) }
}

/// Segment meter for the LCD.
struct SegmentMeter: View {
    let value: Double
    var segments = 32
    var lit: Color = Theme.lcdText
    var unlit: Color = Theme.lcdDim

    var body: some View {
        GeometryReader { geo in
            let gap: CGFloat = 2
            let w = (geo.size.width - gap * CGFloat(segments - 1)) / CGFloat(segments)
            HStack(spacing: gap) {
                ForEach(0..<segments, id: \.self) { i in
                    let on = Double(i) < value * Double(segments)
                    Rectangle()
                        .fill(on ? lit : unlit)
                        .frame(width: max(1, w))
                        .shadow(color: on ? lit.opacity(0.5) : .clear, radius: 2)
                }
            }
        }
    }
}

/// A countersunk screw head — used sparingly, at the corners of the main plate.
struct Screw: View {
    var angle: Double = 20
    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [Color(white: 0.86), Color(white: 0.62)],
                                         center: .init(x: 0.35, y: 0.3), startRadius: 0, endRadius: 6))
            Circle().strokeBorder(.black.opacity(0.25), lineWidth: 0.5)
            Capsule().fill(.black.opacity(0.45)).frame(width: 6.5, height: 1.3).rotationEffect(.degrees(angle))
        }
        .frame(width: 9, height: 9)
        .shadow(color: .white.opacity(0.6), radius: 0, y: 0.5)
    }
}

enum Format {
    static func bytes(_ n: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }

    static func megabytes(_ mb: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(mb) * 1_048_576, countStyle: .file)
    }

    /// Compact LCD-style size: `71.4G`, `734M`.
    static func compact(bytes n: Int) -> String {
        let g = Double(n) / 1_000_000_000
        if g >= 10 { return String(format: "%.0fG", g) }
        if g >= 1 { return String(format: "%.1fG", g) }
        return String(format: "%.0fM", Double(n) / 1_000_000)
    }

    static func duration(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }

    static func eta(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "menos de 1 min" }
        let f = DateComponentsFormatter()
        f.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        f.unitsStyle = .abbreviated
        f.calendar?.locale = Locale(identifier: "es")
        return f.string(from: seconds) ?? ""
    }

    static let dayHeader: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es")
        f.setLocalizedDateFormatFromTemplate("EEEE d MMMM yyyy")
        return f
    }()

    static let shortDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es")
        f.setLocalizedDateFormatFromTemplate("EEE d MMM yyyy")
        return f
    }()

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es")
        f.setLocalizedDateFormatFromTemplate("HH:mm")
        return f
    }()

    static func day(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Hoy" }
        if cal.isDateInYesterday(date) { return "Ayer" }
        return shortDay.string(from: date).replacingOccurrences(of: ".", with: "")
    }

    static func resolutionLabel(_ res: String?) -> String? {
        guard let res, let h = res.split(separator: "x").last.flatMap({ Int($0) }),
              let w = res.split(separator: "x").first.flatMap({ Int($0) }) else { return nil }
        switch max(w, h) {
        case 3840, 4096: return "4K"
        case 2688, 2720: return "2.7K"
        case 1920: return "1080P"
        case 3072: return "3K"
        default: return "\(max(w, h))P"
        }
    }
}
