import AppKit
import SwiftUI

/// Design tokens. One warm accent on the system's neutral surfaces; serif (New York) only for the
/// big screen titles; an 8-pt spacing grid.
enum Theme {
    /// Warm ember — brighter in dark mode so it holds contrast.
    static let accent = Color(nsColor: NSColor(name: "OsmoticAccent") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.96, green: 0.49, blue: 0.29, alpha: 1)
            : NSColor(srgbRed: 0.85, green: 0.38, blue: 0.18, alpha: 1)
    })

    static let success = Color(nsColor: .systemGreen)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let window = Color(nsColor: .windowBackgroundColor)
    static let hairline = Color(nsColor: .separatorColor)

    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 16
    static let s4: CGFloat = 24
    static let s5: CGFloat = 32
    static let s6: CGFloat = 48

    static let radiusS: CGFloat = 6
    static let radiusM: CGFloat = 10
    static let radiusL: CGFloat = 14

    static func display(_ size: CGFloat = 30) -> Font { .system(size: size, weight: .semibold, design: .serif) }
}

extension View {
    /// A raised card on the window background.
    func card(padding: CGFloat = Theme.s3) -> some View {
        self.padding(padding)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusL, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusL, style: .continuous).strokeBorder(Theme.hairline.opacity(0.6)))
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
        return dayHeader.string(from: date).capitalized(with: Locale(identifier: "es"))
    }

    static func resolutionLabel(_ res: String?) -> String? {
        guard let res, let h = res.split(separator: "x").last.flatMap({ Int($0) }),
              let w = res.split(separator: "x").first.flatMap({ Int($0) }) else { return nil }
        let short = min(w, h), long = max(w, h)
        switch (long, short) {
        case (3840, _), (4096, _): return "4K"
        case (2688, _), (2720, _): return "2.7K"
        case (1920, _): return "1080p"
        case (3072, _): return "3K"
        default: return "\(long)p"
        }
    }
}
