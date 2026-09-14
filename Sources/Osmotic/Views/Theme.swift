import AppKit
import SwiftUI

/// Design tokens — "cassette futurism", the same family as Droptape: warm grey ground, off-white
/// hardware panels, ink black, one signal orange; a tight heavy grotesk for display and monospaced
/// uppercase for every label and readout, like the silkscreen on a Teenage Engineering device.
enum Theme {
    private static func dynamic(_ name: String, light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name(name)) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    private static func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
    }

    /// Signal orange (Droptape #FF6B35).
    static let accent = dynamic("OsmoticAccent", light: rgb(255, 107, 53), dark: rgb(255, 122, 72))
    /// Warm grey ground (#E8E6E1).
    static let window = dynamic("OsmoticGround", light: rgb(232, 230, 225), dark: rgb(22, 22, 21))
    /// Hardware panel.
    static let surface = dynamic("OsmoticPanel", light: rgb(245, 244, 240), dark: rgb(34, 34, 32))
    /// Recessed well (thumbnail placeholders, meters).
    static let well = dynamic("OsmoticWell", light: rgb(222, 219, 212), dark: rgb(46, 46, 43))
    /// Ink (#1C1C1C).
    static let ink = dynamic("OsmoticInk", light: rgb(28, 28, 28), dark: rgb(236, 234, 229))
    static let muted = dynamic("OsmoticMuted", light: rgb(112, 108, 102), dark: rgb(150, 146, 140))
    static let hairline = dynamic("OsmoticHairline", light: rgb(0, 0, 0, 0.09), dark: rgb(255, 255, 255, 0.09))
    /// The LCD: black in both modes.
    static let lcd = Color(nsColor: rgb(24, 24, 23))
    static let lcdText = Color(nsColor: rgb(236, 234, 229))
    static let success = Color(nsColor: rgb(76, 175, 80))
    static let warning = Color(nsColor: rgb(255, 176, 32))
    static let danger = Color(nsColor: rgb(226, 62, 48))

    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 16
    static let s4: CGFloat = 24
    static let s5: CGFloat = 32
    static let s6: CGFloat = 48

    static let radiusS: CGFloat = 6
    static let radiusM: CGFloat = 12
    static let radiusL: CGFloat = 18

    /// Display: heavy, tight grotesk.
    static func display(_ size: CGFloat = 30) -> Font { .system(size: size, weight: .heavy, design: .default) }
    /// Silkscreen label: small mono caps (apply `.tracking(1.6)` and uppercase text).
    static func label(_ size: CGFloat = 10.5) -> Font { .system(size: size, weight: .semibold, design: .monospaced) }
    /// Readout: mono numerals.
    static func readout(_ size: CGFloat = 13, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Components

extension View {
    /// A flat hardware panel on the ground.
    func card(padding: CGFloat = Theme.s3) -> some View {
        self.padding(padding)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusL, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusL, style: .continuous).strokeBorder(Theme.hairline))
            .shadow(color: .black.opacity(0.05), radius: 12, y: 4)
    }
}

/// Uppercase monospaced label — the silkscreen text of the device.
struct Silk: View {
    let text: String
    var color: Color = Theme.muted
    var size: CGFloat = 10.5

    init(_ text: String, color: Color = Theme.muted, size: CGFloat = 10.5) {
        self.text = text
        self.color = color
        self.size = size
    }

    var body: some View {
        Text(text.uppercased())
            .font(Theme.label(size))
            .tracking(1.6)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

/// An LED: a lit dot with a glow, and optionally its label.
struct LED: View {
    enum State { case off, on, blink }
    var color: Color = Theme.accent
    var state: State = .on
    var label: String? = nil
    @SwiftUI.State private var phase = false

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(state == .off ? Theme.well : color)
                .frame(width: 7, height: 7)
                .shadow(color: state == .off ? .clear : color.opacity(0.85), radius: 5)
                .opacity(state == .blink && phase ? 0.25 : 1)
                .animation(state == .blink ? .easeInOut(duration: 0.7).repeatForever() : .default, value: phase)
                .onAppear { phase = true }
            if let label { Silk(label, color: state == .off ? Theme.muted : color) }
        }
    }
}

/// Section index, e.g. `01  CERCA ────`.
struct SectionIndex: View {
    let number: Int
    let title: String
    var trailing: AnyView? = nil

    var body: some View {
        HStack(spacing: Theme.s2) {
            Text(String(format: "%02d", number))
                .font(Theme.readout(11, weight: .bold))
                .foregroundStyle(Theme.accent)
            Silk(title, color: Theme.ink)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            if let trailing { trailing }
        }
    }
}

/// Pill hardware key: ink (primary) or orange (signal).
struct KeyButtonStyle: ButtonStyle {
    enum Kind { case ink, signal, ghost }
    var kind: Kind = .ink
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        let fg: Color = kind == .ghost ? Theme.ink : .white
        let bg: Color = switch kind {
        case .ink: Theme.ink
        case .signal: Theme.accent
        case .ghost: Theme.well
        }
        return configuration.label
            .font(Theme.label(compact ? 10.5 : 11.5))
            .tracking(1.4)
            .textCase(.uppercase)
            .foregroundStyle(fg)
            .padding(.horizontal, compact ? 12 : 18)
            .padding(.vertical, compact ? 6 : 10)
            .background(bg, in: Capsule())
            .shadow(color: (kind == .signal ? Theme.accent : .black).opacity(kind == .ghost ? 0 : 0.22),
                    radius: configuration.isPressed ? 2 : 8, y: configuration.isPressed ? 1 : 4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == KeyButtonStyle {
    static var key: KeyButtonStyle { KeyButtonStyle() }
    static var signalKey: KeyButtonStyle { KeyButtonStyle(kind: .signal) }
    static var ghostKey: KeyButtonStyle { KeyButtonStyle(kind: .ghost, compact: true) }
}

/// A segmented meter (VU style): `segments` cells, lit up to `value` (0…1).
struct SegmentMeter: View {
    let value: Double
    var segments = 32
    var lit: Color = Theme.accent
    var unlit: Color = Color.white.opacity(0.12)

    var body: some View {
        GeometryReader { geo in
            let gap: CGFloat = 2
            let w = (geo.size.width - gap * CGFloat(segments - 1)) / CGFloat(segments)
            HStack(spacing: gap) {
                ForEach(0..<segments, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Double(i) < value * Double(segments) ? lit : unlit)
                        .frame(width: max(1, w))
                }
            }
        }
    }
}

enum Format {
    static func bytes(_ n: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }

    static func megabytes(_ mb: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(mb) * 1_048_576, countStyle: .file)
    }

    static func duration(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// `01:12` style countdown for the LCD.
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
