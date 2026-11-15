import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

/// Colours and type of the app, matching the design canvas.
enum Theme {
    static let accent = Color(hex: 0xFF6B1A)
    static let accentSoft = Color(hex: 0xFF8A3D)
    static let onAccent = Color(hex: 0x170A02)
    static let background = Color(hex: 0x0B0D12)
    static let tile = Color(hex: 0x151821)
    static let track = Color(hex: 0x1E222C)
    static let chip = Color(hex: 0x1B1F29)
    static let barBase = Color(hex: 0x0E1016)
    static let label = Color.white.opacity(0.62)
    static let secondary = Color.white.opacity(0.66)
    static let heart = Color(hex: 0xFF5C7A)
    static let ok = Color(hex: 0x3BD16F)
    static let warn = Color(hex: 0xFFD23F)
    static let bad = Color(hex: 0xFF4545)
    static let intervals = Color(hex: 0x6CB4FF)
    static let backdrop = Color(hex: 0x3A4150)

    /// Z1…Z6: grey, blue, green, yellow, orange, red.
    static let zoneColors: [Color] = [0xA3ACB9, 0x3D9BFF, 0x3BD16F, 0xFFD23F, 0xFF8A1F, 0xFF4545].map { Color(hex: $0) }

    static func zoneColor(_ index: Int) -> Color {
        zoneColors[Swift.min(zoneColors.count - 1, Swift.max(0, index))]
    }

    /// Descent teal, flat green, 3–6 % yellow, 6–9 % orange, above red.
    static func gradeColor(_ grade: Double) -> Color {
        switch grade {
        case ..<(-1): return Color(hex: 0x2ED3C6)
        case ..<3: return Color(hex: 0x3BD16F)
        case ..<6: return Color(hex: 0xFFD23F)
        case ..<9: return Color(hex: 0xFF8A1F)
        default: return Color(hex: 0xFF4545)
        }
    }

    static func complianceColor(_ c: TargetCompliance) -> Color {
        switch c {
        case .inTarget: return ok
        case .tooLow: return warn
        case .tooHigh: return bad
        }
    }

    static let gradeLegend: [(label: String, color: Color)] = [
        ("Abfahrt", gradeColor(-3)),
        ("0–3 %", gradeColor(1)),
        ("3–6 %", gradeColor(4)),
        ("6–9 %", gradeColor(7)),
        ("über 9 %", gradeColor(10)),
    ]

    /// Big numbers: SF Pro condensed, tabular digits.
    static func number(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight).width(.condensed).monospacedDigit()
    }

    static func text(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight)
    }
}

/// German number formatting.
enum Fmt {
    static func decimal(_ value: Double, _ digits: Int = 1) -> String {
        String(format: "%.\(digits)f", value).replacingOccurrences(of: ".", with: ",")
    }

    /// 0:42:10 (always with hours) or 32:46.
    static func clock(_ seconds: TimeInterval, hours: Bool) -> String {
        let s = Int(Swift.max(0, seconds).rounded(.down))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if hours || h > 0 {
            return String(format: "%d:%02d:%02d", h, m, sec)
        }
        return String(format: "%d:%02d", m, sec)
    }

    static func km(_ meters: Double) -> String {
        decimal(meters / 1000, 1)
    }

    static func signedGrade(_ grade: Double) -> String {
        (grade < -0.05 ? "−" : "") + decimal(abs(grade), 1)
    }
}
