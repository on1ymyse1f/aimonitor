import SwiftUI

/// Design tokens, mirroring the approved mockup: solid surfaces, hairline
/// borders, small letter-spaced section labels, monospaced numerals.
enum Theme {
    // Surfaces
    static let window = Color(nsColor: NSColor(red: 0.976, green: 0.976, blue: 0.969, alpha: 1))   // #F9F9F7
    static let card = Color(nsColor: .white)
    static let border = Color(nsColor: NSColor(red: 0.898, green: 0.898, blue: 0.878, alpha: 1))  // #E5E5E0
    static let trackFill = Color.primary.opacity(0.07)

    // Text
    static let text = Color(nsColor: NSColor(red: 0.13, green: 0.13, blue: 0.12, alpha: 1))
    static let textSecondary = Color(nsColor: NSColor(red: 0.42, green: 0.42, blue: 0.40, alpha: 1))
    static let textMuted = Color(nsColor: NSColor(red: 0.60, green: 0.60, blue: 0.58, alpha: 1))

    // Accents (from the mockup)
    static let purple = Color(red: 0.498, green: 0.467, blue: 0.867)   // #7F77DD
    static let purpleSoft = Color(red: 0.686, green: 0.663, blue: 0.925)
    static let coral = Color(red: 0.847, green: 0.353, blue: 0.188)    // #D85A30
    static let teal = Color(red: 0.114, green: 0.620, blue: 0.459)     // #1D9E75
    static let blue = Color(red: 0.216, green: 0.541, blue: 0.867)     // #378ADD
    static let gray = Color(red: 0.533, green: 0.529, blue: 0.502)     // #888780
    static let amber = Color(red: 0.937, green: 0.624, blue: 0.153)    // #EF9F27
    static let amberText = Color(red: 0.522, green: 0.310, blue: 0.043)

    // Active-now card
    static let activeBg = Color(red: 0.918, green: 0.953, blue: 0.871) // #EAF3DE
    static let activeDot = Color(red: 0.388, green: 0.600, blue: 0.133)
    static let activeLabel = Color(red: 0.231, green: 0.427, blue: 0.067)
    static let activeText = Color(red: 0.090, green: 0.204, blue: 0.016)

    static let providerColors: [Color] = [purple, coral, teal, blue, gray]

    static func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .tracking(1.4)
            .foregroundStyle(textMuted)
    }

    static func number(_ text: String, size: CGFloat = 16, weight: Font.Weight = .medium) -> some View {
        Text(text)
            .font(.system(size: size, weight: weight, design: .monospaced))
            .foregroundStyle(Theme.text)
    }
}

extension View {
    /// White card with a hairline border, 12pt radius — the mockup's surface.
    func card(padding: CGFloat = 12) -> some View {
        self
            .padding(padding)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 0.5))
    }
}
