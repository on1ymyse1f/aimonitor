import SwiftUI

/// Claude-design-language tokens: warm ivory surfaces, one terracotta accent,
/// serif display numerals, hierarchy through spacing and type rather than
/// borders and boxes.
enum Theme {
    // Surfaces — warm, never pure white on pure gray
    static let window = Color(red: 0.961, green: 0.957, blue: 0.937)   // #F5F4EF ivory
    static let raised = Color(red: 0.992, green: 0.988, blue: 0.976)   // #FDFCF9 warm white
    static let hairline = Color(red: 0.906, green: 0.898, blue: 0.863) // #E7E5DC

    // Text — warm near-black
    static let text = Color(red: 0.106, green: 0.098, blue: 0.082)     // #1B1915
    static let textSecondary = Color(red: 0.431, green: 0.420, blue: 0.380)
    static let textMuted = Color(red: 0.639, green: 0.627, blue: 0.584)

    // The single accent — Claude terracotta
    static let accent = Color(red: 0.851, green: 0.467, blue: 0.341)   // #D97757
    static let accentSoft = Color(red: 0.925, green: 0.792, blue: 0.729)
    static let accentFaint = accent.opacity(0.12)

    // Bars and tracks
    static let bar = Color(red: 0.184, green: 0.176, blue: 0.153)      // warm charcoal
    static let track = Color(red: 0.918, green: 0.910, blue: 0.875)

    // Live indicator — muted sage, the only other hue
    static let live = Color(red: 0.490, green: 0.608, blue: 0.416)

    // MARK: Type

    /// Section labels: 10pt, letterspaced, muted — quiet by design.
    static func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .tracking(1.6)
            .foregroundStyle(textMuted)
    }

    /// Serif display numerals — the Claude headline voice (New York).
    static func display(_ text: String, size: CGFloat = 30) -> some View {
        Text(text)
            .font(.system(size: size, weight: .regular, design: .serif))
            .foregroundStyle(Theme.text)
    }

    /// Tabular numerals for anything that sits in a column.
    static func mono(_ text: String, size: CGFloat = 12, color: Color = Theme.textSecondary) -> Text {
        Text(text)
            .font(.system(size: size, design: .monospaced))
            .foregroundStyle(color)
    }
}

extension View {
    /// The only elevation in the system: warm white, 14pt radius, no border —
    /// separation comes from the ivory window behind it.
    func raised(padding: CGFloat = 14) -> some View {
        self
            .padding(padding)
            .background(Theme.raised)
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
