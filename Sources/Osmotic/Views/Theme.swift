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
    /// The lit top chamfer of a raised part.
    static let edgeLight = Color.white.opacity(0.09)
    /// The lit lower lip of a cut-out, catching the light from above.
    static let lip = Color.white.opacity(0.06)
    // Recess (a milled pocket in the plate)
    static let recess = rgb(25, 25, 24)
    static let slot = rgb(17, 17, 16)  // the dark channel keys sit in
    // Silkscreen ink
    static let ink = rgb(232, 229, 222)
    static let muted = rgb(160, 157, 150)  // ≥ 4.5:1 on every graphite surface
    // Plastics
    static let accent = rgb(238, 92, 36)  // orange key
    static let accentTop = rgb(206, 70, 20)  // key face: white text stays ≥ 4.5:1 across the gradient
    static let accentBottom = rgb(180, 58, 14)
    static let greyTop = rgb(66, 66, 65)  // graphite key
    static let greyBottom = rgb(53, 53, 52)
    // LCD
    static let lcd = rgb(16, 16, 15)
    static let lcdText = rgb(255, 146, 52)
    static let lcdDim = rgb(255, 146, 52, 0.10)
    static let lcdCaption = rgb(236, 228, 214, 0.55)  // warm white legends on the glass
    // Signals
    static let success = rgb(74, 190, 88)
    static let warning = rgb(255, 176, 32)
    static let danger = rgb(232, 56, 42)

    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 16
    static let s4: CGFloat = 24
    static let s5: CGFloat = 32
    static let s6: CGFloat = 48

    static let radiusS: CGFloat = 5
    static let radiusM: CGFloat = 9
    static let radiusL: CGFloat = 14

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
        let noise = (CIFilter.randomGenerator().outputImage ?? CIImage(color: .gray))
            .cropped(to: CGRect(x: 0, y: 0, width: size + blur * 4, height: size))
        let mono = noise.applyingFilter(
            "CIColorControls",
            parameters: [
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

// MARK: - Depth

/// One shadow, as a value. Every shadow in the app is one of the `Depth` tokens below — never an
/// ad-hoc `.shadow(color:radius:)` — so depth reads the same everywhere.
struct ShadowToken {
    let color: Color
    let radius: CGFloat
    var y: CGFloat = 0
}

/// The light comes from above, and there are only three depths:
/// - **raised** — modules, thumbnails: a soft contact shadow plus a wide, faint ambient one;
/// - **inset** — pockets, key slots, displays: the shadow falls inside, from the top edge;
/// - **glow** — lit things (LEDs, readouts, the latched key's stripe) light their surroundings.
/// Edges carry the light: `Theme.edgeLight` along the top of raised parts, `Theme.lip` along the
/// bottom of cut-outs.
enum Depth {
    static let contact = ShadowToken(color: .black.opacity(0.28), radius: 1.5, y: 1)
    static let ambient = ShadowToken(color: .black.opacity(0.14), radius: 14, y: 6)
    /// Small parts sitting on a picture (checkbox, play button).
    static let onImage = ShadowToken(color: .black.opacity(0.35), radius: 2, y: 1)
    static let inset = ShadowToken(color: .black.opacity(0.55), radius: 3, y: 1.5)
    static let insetDeep = ShadowToken(color: .black.opacity(0.75), radius: 4, y: 2)
    /// The lit lip under a small cut-out (screw head).
    static let lipLight = ShadowToken(color: Theme.lip, radius: 0, y: 0.5)
    static func glow(_ color: Color, _ strength: Double = 0.35) -> ShadowToken {
        ShadowToken(color: color.opacity(strength), radius: 3)
    }
    /// The wider halo a lit lens throws on the plate around it (only LEDs use it, over `glow`).
    static func bloom(_ color: Color, _ strength: Double = 0.22) -> ShadowToken {
        ShadowToken(color: color.opacity(strength), radius: 9)
    }
}

extension View {
    func shadow(_ t: ShadowToken) -> some View { shadow(color: t.color, radius: t.radius, y: t.y) }
    /// Raised off the plate.
    func raisedShadow() -> some View { shadow(Depth.contact).shadow(Depth.ambient) }
}

extension ShadowStyle {
    static func inner(_ t: ShadowToken) -> ShadowStyle { .inner(color: t.color, radius: t.radius, y: t.y) }
}

// MARK: - Motion

/// How things move. Every animation in the app is one of these — never an ad-hoc `.smooth` or
/// `.snappy` — and each one is borrowed from how the hardware it imitates behaves:
/// - keys go **down** fast and hard (`press`) and come back **up** on their spring, a hair past rest
///   (`release`);
/// - modules and trays slide in on rails, well damped (`panel`);
/// - lights come on in a quick bloom (`bloom`); plain state changes are brief (`quick`);
/// - displays never cross-fade: values change instantly, segment meters step, and a display that
///   appears powers up with a short flicker (`LCDBoot`).
/// With Reduce Motion on, every change is instant (`MotionModifier`).
enum Motion {
    // Ease-out, never ease-in, on anything the user triggers: the key starts moving at once.
    static let press = Animation.easeOut(duration: 0.045)
    // A hair past rest (~2–3% overshoot), like a sprung key coming back up.
    static let release = Animation.spring(response: 0.2, dampingFraction: 0.75)
    static let panel = Animation.spring(response: 0.32, dampingFraction: 0.9)
    static let bloom = Animation.easeOut(duration: 0.14)
    static let quick = Animation.easeOut(duration: 0.1)
}

extension View {
    /// `animation`, or none when the user asked for reduced motion.
    func motion<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(MotionModifier(animation: animation, value: value))
    }
}

private struct MotionModifier<V: Equatable>: ViewModifier {
    let animation: Animation
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension AnyTransition {
    /// A module sliding out from under the part above it.
    static var panelFromTop: AnyTransition { .move(edge: .top).combined(with: .opacity) }
    /// A tray sliding up from the bottom edge.
    static var trayFromBottom: AnyTransition { .move(edge: .bottom).combined(with: .opacity) }
}

/// A display powering up: dark, a flash, a dip, then steady — about 150 ms, once per appearance.
struct LCDBoot: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var level = 1.0

    func body(content: Content) -> some View {
        content
            .opacity(level)
            .task {
                // Debug snapshots render a single frame: never catch the display mid-flicker.
                guard !reduceMotion, ProcessInfo.processInfo.environment["OSMOTIC_SNAPSHOT"] == nil else { return }
                defer { level = 1 }  // however the sequence ends (cancelled, interrupted), end lit
                for (value, ms) in [(0.0, 45), (0.75, 55), (0.2, 45)] {
                    level = value
                    try? await Task.sleep(for: .milliseconds(ms))
                    if Task.isCancelled { return }
                }
            }
    }
}

/// A pocket cut into the plate, filled with `fill`: inner shadow from the top, a lit lip at the bottom.
struct Pocket: ViewModifier {
    var fill: Color = Theme.recess
    var radius: CGFloat = Theme.radiusM
    var deep = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background { shape.fill(fill.shadow(.inner(deep ? Depth.insetDeep : Depth.inset))) }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.black.opacity(0.3), .clear, Theme.lip],
                        startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
    }
}

extension View {
    /// A raised module milled from the plate: a lit chamfer along the top, raised shadow below.
    func raisedPanel(radius: CGFloat = Theme.radiusL, screws: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return
            self
            .background {
                shape.fill(LinearGradient(colors: [Theme.metalTop, Theme.metalBottom], startPoint: .top, endPoint: .bottom))
                    .overlay {
                        BrushedMetal.grain.resizable(resizingMode: .tile).opacity(0.08).blendMode(.softLight).clipShape(shape)
                    }
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: Theme.edgeLight, location: 0),
                            .init(color: .clear, location: 0.4),
                        ], startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
            .overlay { if screws { CornerScrews(inset: min(radius * 0.55, 8) + 2) } }
            .raisedShadow()
    }

    /// A pocket milled into the plate.
    func recessed(radius: CGFloat = Theme.radiusM) -> some View {
        modifier(Pocket(radius: radius))
    }
}

/// A display: a deep pocket of dark glass with a faint glare. Kept quiet on purpose — the readout is
/// the only thing that should glow.
struct LCDGlass<Content: View>: View {
    var radius: CGFloat = Theme.radiusM
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            // Segments switch; they don't fade. Outer animations must not cross-fade the readout.
            .transaction { $0.animation = nil }
            .modifier(LCDBoot())
            .modifier(Pocket(fill: Theme.lcd, radius: radius, deep: true))
            .overlay {
                shape.fill(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.04), location: 0),
                            .init(color: .white.opacity(0.0), location: 0.35),
                        ], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .allowsHitTesting(false)
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
                .shadow(Depth.glow(color))
        }
        .font(.system(size: size, weight: .regular, design: .monospaced))
        .tracking(1.4)
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .combine)
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
        HStack(spacing: 2) { content }
            .padding(compact ? 2 : 3)
            .modifier(Pocket(fill: Theme.slot, radius: compact ? Theme.radiusS + 1 : Theme.radiusM - 1, deep: true))
            .fixedSize()
    }
}

struct CassetteKeyStyle: ButtonStyle {
    enum Finish { case primary, secondary }
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var finish: Finish = .secondary
    var compact = false
    var latched = false
    /// Minimum width; keys still grow to fit a longer label.
    var width: CGFloat? = nil

    func makeBody(configuration: Configuration) -> some View {
        let down = latched || configuration.isPressed
        let height: CGFloat = compact ? 26 : 36
        let travel: CGFloat = compact ? 4 : 6  // front edge visible when the key is up
        let sink: CGFloat = down ? travel - 1.5 : 0  // how far the face drops into the slot
        let (top, bottom, skirt, text): (Color, Color, Color, Color) =
            switch finish {
            case .secondary: (Theme.greyTop, Theme.greyBottom, Color(white: 0.14), Theme.ink)
            case .primary: (Theme.accentTop, Theme.accentBottom, Color(red: 0.52, green: 0.2, blue: 0.05), .white)
            }
        let face = configuration.label
            .labelStyle(KeyLabelStyle())
            .font(.system(size: compact ? 9 : 9.5, weight: .semibold))
            .tracking(0.9)
            .textCase(.uppercase)
            .foregroundStyle(text.opacity(down && finish == .secondary ? 0.8 : 1))
            .padding(.horizontal, width == nil ? (compact ? 10 : 14) : 8)
            .frame(minWidth: width ?? 44)  // grows for longer translations
            .frame(height: height)
            .background {
                // Face: lit from above; flatter and darker once pushed into the slot.
                Rectangle().fill(
                    LinearGradient(
                        colors: down ? [bottom.opacity(0.94), bottom] : [top, bottom],
                        startPoint: .top, endPoint: .bottom))
            }
            .overlay(alignment: .top) {
                if latched {
                    Rectangle().fill(
                        LinearGradient(colors: [Theme.accentTop, Theme.accentBottom], startPoint: .top, endPoint: .bottom)
                    )
                    .frame(height: 4)
                    .shadow(Depth.glow(Theme.accent, 0.5))
                } else if !down {
                    Rectangle().fill(.white.opacity(finish == .primary ? 0.3 : 0.12)).frame(height: 1)
                }
            }
            .overlay {
                if down {  // the slot's walls shade the top of a sunk key
                    LinearGradient(
                        colors: [.black.opacity(0.38), .black.opacity(0.06)], startPoint: .top, endPoint: .init(x: 0.5, y: 0.6)
                    )
                    .allowsHitTesting(false)
                }
            }
            // Side bevels keep neighbouring keys distinct.
            .overlay(alignment: .leading) { Rectangle().fill(.white.opacity(0.07)).frame(width: 1) }
            .overlay(alignment: .trailing) { Rectangle().fill(.black.opacity(0.3)).frame(width: 1) }

        return
            face
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
            .animation(reduceMotion ? nil : (down ? Motion.press : Motion.release), value: down)
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
            .shadow(Depth.glow(color))
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
            HStack {
                dot; Spacer(); dot
            }
            Spacer()
            HStack {
                dot; Spacer(); dot
            }
        }
        .padding(inset)
        .allowsHitTesting(false)
    }
    private var dot: some View {
        Circle()
            .fill(Color.black.opacity(0.55))
            .frame(width: 3.5, height: 3.5)
            .shadow(Depth.lipLight)
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
    /// What VoiceOver says about the light; defaults to on / off / blinking.
    var spokenState: LocalizedStringKey? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 7) {
            // A blinking LED pulses its brightness (never reads as switched off). Driven by the clock,
            // so it starts and stops with `state` and nothing keeps animating afterwards.
            if state == .blink && !reduceMotion && AppVisibility.shared.visible {
                // On/dim every 0.6 s, like a real LED — two redraws a second instead of a continuous
                // animation; steady while the window isn't on screen (no timeline running at all).
                TimelineView(.periodic(from: .now, by: 0.6)) { t in
                    let dimmed = Int(t.date.timeIntervalSinceReferenceDate / 0.6) % 2 == 1
                    lens(dim: dimmed ? 0.55 : 0)
                }
            } else {
                lens(dim: 0)
                    .motion(Motion.bloom, value: state)
            }
            if let label { Silk(label, color: Theme.ink) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(
            spokenState.map { Text($0) }
                ?? (state == .off ? Text("Off") : state == .blink ? Text("Blinking") : Text("On")))
    }

    /// A real panel lamp, in three parts: the hole it sits in, the domed lens (bright just above
    /// the middle, darker at the limb) and the specular dot where the light above it lands.
    private func lens(dim: Double) -> some View {
        let lit = state != .off
        return ZStack {
            // The bezel: a dark hole whose bottom edge catches the light, like every cut-out here.
            Circle()
                .fill(Color.black.opacity(0.6))
                .frame(width: size + 3, height: size + 3)
                .overlay {
                    Circle().strokeBorder(
                        LinearGradient(
                            colors: [.black.opacity(0.7), Theme.lip.opacity(0.9)],
                            startPoint: .top, endPoint: .bottom),
                        lineWidth: 1)
                }
            Circle()
                .fill(
                    RadialGradient(
                        colors: lit
                            ? [color.opacity(1), color.opacity(0.94), color.opacity(0.7)]
                            : [Color(white: 0.17), Color(white: 0.08)],
                        center: .init(x: 0.44, y: 0.4), startRadius: 0, endRadius: size * 0.62)
                )
                // Limb darkening: the lens is a dome, so its edge turns away from the eye.
                .overlay {
                    Circle().fill(
                        RadialGradient(
                            colors: [.clear, .black.opacity(lit ? 0.35 : 0.5)],
                            center: .center, startRadius: size * 0.2, endRadius: size * 0.52))
                }
                .frame(width: size, height: size)
                .opacity(1 - dim)
            Circle().fill(.white.opacity(lit ? 0.9 : 0.12))
                .frame(width: size * 0.26, height: size * 0.26)
                .blur(radius: size * 0.04)
                .offset(x: -size * 0.17, y: -size * 0.19)
        }
        .shadow(Depth.glow(lit ? color : .clear, 0.65 * (1 - dim)))
        .shadow(Depth.bloom(lit ? color : .clear, 0.28 * (1 - dim)))
        .accessibilityHidden(true)
    }
}

/// Section header printed on the plate: `01 NEARBY` with a thin engraved rule.
struct SectionIndex: View {
    let number: Int
    let title: LocalizedStringKey
    var trailing: AnyView? = nil

    var body: some View {
        HStack(spacing: Theme.s2) {
            Text(String(format: "%02ld", number))
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
        // One Canvas instead of a view per segment: the transfer bar redraws on every progress tick.
        Canvas { ctx, size in
            let gap: CGFloat = 2
            let w = max(1, (size.width - gap * CGFloat(segments - 1)) / CGFloat(segments))
            let litCount = Int((value * Double(segments)).rounded(.up))
            func rect(_ i: Int) -> Path { Path(CGRect(x: CGFloat(i) * (w + gap), y: 0, width: w, height: size.height)) }
            for i in litCount..<max(litCount, segments) { ctx.fill(rect(i), with: .color(unlit)) }
            ctx.drawLayer { lit in
                lit.addFilter(.shadow(color: self.lit.opacity(0.35), radius: 3))
                for i in 0..<min(litCount, segments) { lit.fill(rect(i), with: .color(self.lit)) }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Progress"))
        .accessibilityValue(Text(verbatim: "\(Int((min(1, max(0, value)) * 100).rounded()))%"))
    }
}

enum Format {
    static func bytes(_ n: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }

    static func megabytes(_ mb: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(mb) * 1_048_576, countStyle: .file)
    }

    /// Compact LCD-style size: `71.4G`, `734M` (decimal separator follows the user's locale).
    static func compact(bytes n: Int) -> String {
        let g = Double(n) / 1_000_000_000
        if g >= 10 { return g.formatted(.number.precision(.fractionLength(0))) + "G" }
        if g >= 1 { return g.formatted(.number.precision(.fractionLength(1))) + "G" }
        return (Double(n) / 1_000_000).formatted(.number.precision(.fractionLength(0))) + "M"
    }

    static func duration(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%ld:%02ld:%02ld", h, m, s) : String(format: "%ld:%02ld", m, s)
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        return s >= 3600
            ? String(format: "%ld:%02ld:%02ld", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%02ld:%02ld", s / 60, s % 60)
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

    /// Day and time in one template, so each language orders them its own way.
    static let dayAndTime: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEE d MMMM yyyy jmm")
        return f
    }()

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("jmm")  // 12- or 24-hour, as the user has it
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
            let w = res.split(separator: "x").first.flatMap({ Int($0) })
        else { return nil }
        switch max(w, h) {
        case 3840, 4096: return "4K"
        case 2688, 2720: return "2.7K"
        case 1920: return "1080P"
        case 3072: return "3K"
        default: return "\(max(w, h))P"
        }
    }
}
