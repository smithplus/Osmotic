import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Design tokens for Osmotic as a physical object: a graphite anodised faceplate, moulded keys, dark
/// glass readouts and lens LEDs. One light source, from above: every raised part has a faint lit top
/// edge and a contact shadow below; every recessed part has its shadow inside, at the top. Type is
/// silkscreen — small, printed, warm white on graphite — and amber on the displays.
enum Theme {
    private static func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> Color {
        Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: a)
    }

    // Faceplate (graphite anodised aluminium) and the modules milled from it
    static let plateTop = rgb(36, 36, 35)
    static let plateBottom = rgb(29, 29, 28)
    static let metalTop = rgb(47, 47, 46)
    static let metalBottom = rgb(40, 40, 39)
    static let metalEdgeLight = Color.white.opacity(0.10)
    static let metalEdgeDark = rgb(0, 0, 0, 0.5)
    /// The lit lower lip of a cut-out, catching the light from above.
    static let lip = Color.white.opacity(0.06)
    // Recess (a milled pocket in the plate)
    static let recess = rgb(25, 25, 24)
    // Silkscreen ink
    static let ink = rgb(232, 229, 222)
    static let muted = rgb(138, 135, 129)
    static let hairline = rgb(255, 255, 255, 0.08)
    // Plastics
    static let accent = rgb(238, 92, 36)            // orange key
    static let accentTop = rgb(247, 114, 60)
    static let accentBottom = rgb(214, 74, 22)
    static let charcoalTop = rgb(30, 30, 29)
    static let charcoalBottom = rgb(19, 19, 18)
    static let greyTop = rgb(66, 66, 65)            // graphite key
    static let greyBottom = rgb(53, 53, 52)
    // LCD
    static let lcd = rgb(16, 16, 15)
    static let lcdText = rgb(255, 146, 52)
    static let lcdDim = rgb(255, 146, 52, 0.10)
    static let lcdCaption = rgb(236, 228, 214, 0.55)          // warm white legends on the glass
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
    static func label(_ size: CGFloat = 9.5) -> Font { .system(size: size, weight: .medium, design: .default) }
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

/// The faceplate: graphite gradient + a trace of brushed grain.
struct AluminumPlate: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.plateTop, Theme.plateBottom], startPoint: .top, endPoint: .bottom)
            BrushedMetal.grain
                .resizable(resizingMode: .tile)
                .opacity(0.10)
                .blendMode(.softLight)
        }
    }
}

extension View {
    /// A raised module milled from the plate: lit top edge, contact shadow.
    func raisedPanel(radius: CGFloat = Theme.radiusL, screws: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            .background {
                shape.fill(LinearGradient(colors: [Theme.metalTop, Theme.metalBottom.opacity(0.96)],
                                          startPoint: .top, endPoint: .bottom))
                    .overlay { BrushedMetal.grain.resizable(resizingMode: .tile).opacity(0.08).blendMode(.softLight).clipShape(shape) }
            }
            .overlay {
                // Machined edge: a bright chamfer on top, the darker side of the part at the bottom.
                shape.strokeBorder(LinearGradient(stops: [
                    .init(color: Theme.metalEdgeLight, location: 0),
                    .init(color: .white.opacity(0.03), location: 0.3),
                    .init(color: .black.opacity(0.15), location: 0.7),
                    .init(color: Theme.metalEdgeDark, location: 1),
                ], startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
            .overlay { if screws { CornerScrews(inset: min(radius * 0.55, 8) + 2) } }
            .shadow(color: .black.opacity(0.45), radius: 0, y: 1)      // hard contact edge
            .shadow(color: .black.opacity(0.28), radius: 9, y: 5)
    }

    /// A pocket milled into the plate: shadow inside at the top, a lit lip at the bottom.
    func recessed(radius: CGFloat = Theme.radiusM) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            .background {
                shape.fill(Theme.recess.shadow(.inner(color: .black.opacity(0.7), radius: 4, y: 2)))
            }
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [.black.opacity(0.4), Theme.lip],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
    }

    /// Back-compat for views that still ask for a card.
    func card(padding: CGFloat = Theme.s3) -> some View { self.padding(padding).raisedPanel() }
}

/// Dark glass display set into the plate: charcoal bezel, recessed glass with a soft inner shadow and
/// a faint glare. Kept quiet on purpose — the readout is the only thing that should glow.
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
                    .init(color: .white.opacity(0.06), location: 0),
                    .init(color: .white.opacity(0.0), location: 0.35),
                ], startPoint: .topLeading, endPoint: .bottomTrailing))
                .allowsHitTesting(false)
            }
            .overlay { shape.strokeBorder(Color.black.opacity(0.6), lineWidth: 1) }
            .padding(4)
            .background {
                RoundedRectangle(cornerRadius: radius + 4, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.charcoalTop, Theme.charcoalBottom], startPoint: .top, endPoint: .bottom))
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius + 4, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.black.opacity(0.6), Theme.lip],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
    }
}

/// `FILES: 29` — a warm-white legend and an amber value on one baseline, like the readouts on studio gear.
struct LCDPair: View {
    let label: LocalizedStringKey
    let value: String
    var size: CGFloat = 11.5
    var color: Color = Theme.lcdText

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            (Text(label) + Text(verbatim: ":"))
                .textCase(.uppercase)
                .foregroundStyle(Theme.lcdCaption)
            Text(verbatim: " " + value)
                .foregroundStyle(color)
                .shadow(color: color.opacity(0.35), radius: 2)
        }
        .font(.system(size: size, weight: .regular, design: .monospaced))
        .tracking(1.4)
        .lineLimit(1)
        .fixedSize()
    }
}

// MARK: - Cassette keys

/// The app's only button: a cassette-deck key, always seated in a dark slot (`CassetteKeyBank`), one
/// key or several side by side. Two finishes — `.primary` (orange) for the one action a screen is
/// for, `.secondary` (graphite) for everything else — and two sizes, regular and `compact`.
/// A key that is up shows its front edge; a latched key sits low in the slot with an orange stripe.
struct CassetteKeyBank<Content: View>: View {
    var compact = false
    @ViewBuilder var content: Content
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: compact ? 6 : 8, style: .continuous)
        HStack(spacing: 2) { content }
            .padding(compact ? 2 : 3)
            .background {
                shape.fill(Color(white: 0.07).shadow(.inner(color: .black.opacity(0.9), radius: 3, y: 2)))
            }
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [.black.opacity(0.5), Theme.lip],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
            .fixedSize()
    }
}

struct CassetteKeyStyle: ButtonStyle {
    enum Finish { case primary, secondary }
    @Environment(\.isEnabled) private var isEnabled
    var finish: Finish = .secondary
    var compact = false
    var latched = false
    /// Minimum width; keys still grow to fit a longer label.
    var width: CGFloat? = nil

    func makeBody(configuration: Configuration) -> some View {
        let down = latched || configuration.isPressed
        let height: CGFloat = compact ? 26 : 36
        let travel: CGFloat = compact ? 4 : 6                 // front edge visible when the key is up
        let sink: CGFloat = down ? travel - 1.5 : 0           // how far the face drops into the slot
        let (top, bottom, skirt, text): (Color, Color, Color, Color) = switch finish {
        case .secondary: (Theme.greyTop, Theme.greyBottom, Color(white: 0.14), Theme.ink)
        case .primary: (Theme.accentTop, Theme.accentBottom, Color(red: 0.52, green: 0.2, blue: 0.05), .white)
        }
        let face = configuration.label
            .labelStyle(KeyLabelStyle())
            .font(.system(size: compact ? 9 : 9.5, weight: .semibold))
            .tracking(0.9)
            .textCase(.uppercase)
            .foregroundStyle(text.opacity(down && finish == .secondary ? 0.8 : 1))
            .padding(.horizontal, width == nil ? (compact ? 10 : 14) : 0)
            .frame(minWidth: width ?? 44)             // grows for longer translations
            .frame(height: height)
            .background {
                // Face: lit from above; flatter and darker once pushed into the slot.
                Rectangle().fill(LinearGradient(colors: down ? [bottom.opacity(0.94), bottom] : [top, bottom],
                                                startPoint: .top, endPoint: .bottom))
            }
            .overlay(alignment: .top) {
                if latched {
                    Rectangle().fill(LinearGradient(colors: [Theme.accentTop, Theme.accentBottom], startPoint: .top, endPoint: .bottom))
                        .frame(height: 4)
                        .shadow(color: Theme.accent.opacity(0.6), radius: 2, y: 1)
                } else if !down {
                    Rectangle().fill(.white.opacity(finish == .primary ? 0.3 : 0.12)).frame(height: 1)
                }
            }
            .overlay {
                if down {   // the slot's walls shade the top of a sunk key
                    LinearGradient(colors: [.black.opacity(0.38), .black.opacity(0.06)], startPoint: .top, endPoint: .init(x: 0.5, y: 0.6))
                        .allowsHitTesting(false)
                }
            }
            // Side bevels keep neighbouring keys distinct.
            .overlay(alignment: .leading) { Rectangle().fill(.white.opacity(0.07)).frame(width: 1) }
            .overlay(alignment: .trailing) { Rectangle().fill(.black.opacity(0.3)).frame(width: 1) }

        return face
            .offset(y: sink)
            .padding(.bottom, travel)
            .background(alignment: .bottom) {
                Rectangle()
                    .fill(LinearGradient(colors: [skirt, skirt.opacity(0.75)], startPoint: .top, endPoint: .bottom))
                    .frame(height: travel + 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 2.5, style: .continuous))
            .saturation(isEnabled ? 1 : 0.2)
            .opacity(isEnabled ? 1 : 0.55)
            .contentShape(Rectangle())
            .animation(.snappy(duration: 0.07), value: down)
    }
}

/// Amber LCD text: regular-weight mono, generously tracked, with a soft glow.
struct LCDText: View {
    let text: String
    var size: CGFloat = 13
    var weight: Font.Weight = .regular
    var color: Color = Theme.lcdText

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: weight, design: .monospaced))
            .tracking(size * 0.11)
            .foregroundStyle(color)
            .shadow(color: color.opacity(0.35), radius: 2)
            .lineLimit(1)
    }
}

/// Printed group legend: `VIEW ————` with a little tick at the end, like the brackets on hardware.
struct BankLegend: View {
    let text: LocalizedStringKey
    var body: some View {
        HStack(spacing: 6) {
            Silk(text, color: Theme.ink, size: 8.5)
            Rectangle().fill(Theme.ink.opacity(0.18)).frame(height: 1)
        }
    }
}

/// Four tiny screw heads in the corners of a module.
struct CornerScrews: View {
    var inset: CGFloat = 8
    var body: some View {
        VStack {
            HStack { dot; Spacer(); dot }
            Spacer()
            HStack { dot; Spacer(); dot }
        }
        .padding(inset)
        .allowsHitTesting(false)
    }
    private var dot: some View {
        Circle()
            .fill(Color.black.opacity(0.55))
            .frame(width: 3.5, height: 3.5)
            .shadow(color: Theme.lip, radius: 0, y: 0.5)
    }
}

// MARK: - Controls

/// Silkscreen label printed on the metal.
struct Silk: View {
    let text: Text
    var color: Color = Theme.muted
    var size: CGFloat = 9.5

    init(_ key: LocalizedStringKey, color: Color = Theme.muted, size: CGFloat = 9.5) {
        self.text = Text(key)
        self.color = color
        self.size = size
    }

    init(verbatim string: String, color: Color = Theme.muted, size: CGFloat = 9.5) {
        self.text = Text(verbatim: string)
        self.color = color
        self.size = size
    }

    var body: some View {
        text
            .textCase(.uppercase)
            .font(Theme.label(size))
            .tracking(1.2)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

/// A lens LED: coloured dome with a specular dot; lit ones throw a little light.
struct LED: View {
    enum State { case off, on, blink }
    var color: Color = Theme.accent
    var state: State = .on
    var label: LocalizedStringKey? = nil
    var size: CGFloat = 8
    @SwiftUI.State private var phase = false

    var body: some View {
        HStack(spacing: 7) {
            // A blinking LED pulses its brightness; it never reads as switched off.
            let lit = state != .off
            ZStack {
                Circle().fill(Color.black.opacity(0.7)).frame(width: size + 3, height: size + 3)   // bezel hole
                Circle()
                    .fill(RadialGradient(colors: lit ? [color.opacity(1), color.opacity(0.75), color.opacity(0.45)]
                                                     : [Color(white: 0.16), Color(white: 0.09)],
                                         center: .init(x: 0.4, y: 0.35), startRadius: 0, endRadius: size * 0.7))
                    .frame(width: size, height: size)
                    .opacity(state == .blink && phase ? 0.45 : 1)
                Circle().fill(.white.opacity(lit ? 0.85 : 0.12))
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
    let title: LocalizedStringKey
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
            Rectangle().fill(.black.opacity(0.5)).frame(height: 1)
            Rectangle().fill(Theme.lip).frame(height: 1)
        }
    }
}

/// Icon + title on a key: a small glyph before the printed word.
struct KeyLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

extension ButtonStyle where Self == CassetteKeyStyle {
    static var primaryKey: CassetteKeyStyle { CassetteKeyStyle(finish: .primary) }
    static var secondaryKey: CassetteKeyStyle { CassetteKeyStyle() }
    static var compactKey: CassetteKeyStyle { CassetteKeyStyle(compact: true) }
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
        .shadow(color: Theme.lip, radius: 0, y: 0.5)
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
        if seconds < 60 { return String(localized: "under 1 min") }
        let f = DateComponentsFormatter()
        f.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        f.unitsStyle = .abbreviated
        return f.string(from: seconds) ?? ""
    }

    static let dayHeader: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEE d MMMM yyyy")
        return f
    }()

    static let shortDay: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE d MMM yyyy")
        return f
    }()

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("HH:mm")
        return f
    }()

    static func day(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return String(localized: "Today") }
        if cal.isDateInYesterday(date) { return String(localized: "Yesterday") }
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
