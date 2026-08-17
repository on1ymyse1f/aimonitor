import SwiftUI

/// Claude-design-language tokens: warm ivory in light mode, warm charcoal in
/// dark mode. One terracotta accent. Hierarchy through spacing and type, not
/// borders and boxes.
enum Theme {
    private static func dynamic(_ light: (CGFloat, CGFloat, CGFloat), _ dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let d = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = d ? dark : light
            return NSColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }

    // Surfaces
    static let window = dynamic((0.961, 0.957, 0.937), (0.118, 0.114, 0.102))   // #F5F4EF / #1E1D1A
    static let raised = dynamic((0.992, 0.988, 0.976), (0.165, 0.161, 0.145))   // #FDFCF9 / #2A2925
    static let hairline = dynamic((0.906, 0.898, 0.863), (0.263, 0.255, 0.224))

    // Text — warm
    static let text = dynamic((0.106, 0.098, 0.082), (0.925, 0.914, 0.886))
    static let textSecondary = dynamic((0.431, 0.420, 0.380), (0.659, 0.643, 0.600))
    static let textMuted = dynamic((0.639, 0.627, 0.584), (0.431, 0.420, 0.380))

    // The single accent — Claude terracotta, slightly lifted in dark mode
    static let accent = dynamic((0.851, 0.467, 0.341), (0.878, 0.541, 0.427))
    static let accentSoft = dynamic((0.925, 0.792, 0.729), (0.545, 0.361, 0.278))
    static let accentFaint = accent.opacity(0.12)

    // Bars and tracks
    static let bar = dynamic((0.184, 0.176, 0.153), (0.816, 0.804, 0.769))
    static let track = dynamic((0.918, 0.910, 0.875), (0.227, 0.220, 0.196))

    // Live indicator — muted sage, the only other hue
    static let live = dynamic((0.490, 0.608, 0.416), (0.541, 0.663, 0.463))

    // MARK: Type

    static func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .tracking(1.6)
            .foregroundStyle(textMuted)
    }

    static func display(_ text: String, size: CGFloat = 30) -> some View {
        Text(text)
            .font(.system(size: size, weight: .regular, design: .serif))
            .foregroundStyle(Theme.text)
    }

    static func mono(_ text: String, size: CGFloat = 12, color: Color = Theme.textSecondary) -> Text {
        Text(text)
            .font(.system(size: size, design: .monospaced))
            .foregroundStyle(color)
    }
}

extension View {
    func raised(padding: CGFloat = 14) -> some View {
        self
            .padding(padding)
            .background(Theme.raised)
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
