import SwiftUI

/// Colour scheme of the HUD capsule (Settings › General › HUD).
enum HUDTheme: String, CaseIterable, Codable, Identifiable {
    case freshGreen
    case mint
    case sky
    case indigo
    case violet
    case coral
    case amber
    case graphite
    case snow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .freshGreen: return "Fresh green"
        case .mint: return "Mint"
        case .sky: return "Sky blue"
        case .indigo: return "Indigo"
        case .violet: return "Violet"
        case .coral: return "Coral"
        case .amber: return "Amber"
        case .graphite: return "Graphite"
        case .snow: return "Snow white"
        }
    }

    /// Capsule fill.
    var background: Color {
        switch self {
        case .freshGreen: return Color(red: 0.24, green: 0.86, blue: 0.52)
        case .mint: return Color(red: 0.55, green: 0.93, blue: 0.82)
        case .sky: return Color(red: 0.45, green: 0.78, blue: 1.00)
        case .indigo: return Color(red: 0.30, green: 0.36, blue: 0.85)
        case .violet: return Color(red: 0.62, green: 0.42, blue: 0.95)
        case .coral: return Color(red: 1.00, green: 0.48, blue: 0.42)
        case .amber: return Color(red: 1.00, green: 0.78, blue: 0.25)
        case .graphite: return Color(red: 0.20, green: 0.21, blue: 0.24)
        case .snow: return Color(red: 0.97, green: 0.97, blue: 0.98)
        }
    }

    /// Text and icon colour, chosen for contrast with `background`.
    var ink: Color {
        switch self {
        case .freshGreen: return Color(red: 0.03, green: 0.18, blue: 0.10)
        case .mint: return Color(red: 0.03, green: 0.22, blue: 0.18)
        case .sky: return Color(red: 0.04, green: 0.14, blue: 0.30)
        case .indigo, .violet, .graphite: return Color.white
        case .coral: return Color(red: 0.30, green: 0.05, blue: 0.03)
        case .amber: return Color(red: 0.28, green: 0.17, blue: 0.02)
        case .snow: return Color(red: 0.12, green: 0.13, blue: 0.16)
        }
    }

    /// Colour of the recording level bars.
    var recordingBars: Color {
        switch self {
        case .coral, .amber: return ink
        case .indigo, .violet, .graphite: return Color(red: 1.00, green: 0.42, blue: 0.40)
        default: return Color(red: 0.85, green: 0.12, blue: 0.12)
        }
    }

    /// Hairline around the capsule.
    var border: Color {
        switch self {
        case .indigo, .violet, .graphite: return Color.white.opacity(0.18)
        case .snow: return Color.black.opacity(0.12)
        default: return Color.white.opacity(0.35)
        }
    }
}
