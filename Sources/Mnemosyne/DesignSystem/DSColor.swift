import SwiftUI

// MARK: - Color tokens
// Mnemosyne AI-Native Design System — dark-first, depth via translucency,
// an "intelligence" gradient as the signature of every generative surface.

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

/// `DS` is the single namespace every view reaches into. Never hardcode a
/// color, size, or duration in a view — add a token here and reference it.
public enum DS {}

extension DS {
    // Swiss International style — bright, airy, near-empty. Pure paper-white,
    // near-black ink, a strict grid, and exactly ONE bold accent (vermilion)
    // used only where it matters. No glass, no gradients, no decoration.
    public enum ColorToken {
        public static let canvas        = Color(hex: 0xFCFCFA)   // airy paper
        public static let canvasRaised  = Color(hex: 0xF4F4F1)
        public static let surface       = Color(hex: 0xFFFFFF)   // crisp white card
        public static let surfaceRaised  = Color(hex: 0xFFFFFF)
        public static let surfaceOverlay = Color(hex: 0xF2F2EF)

        // Hairlines — precise ink, low alpha.
        public static let borderSubtle  = Color(hex: 0x111110, alpha: 0.07)
        public static let borderDefault = Color(hex: 0x111110, alpha: 0.13)
        public static let borderStrong  = Color(hex: 0x111110, alpha: 0.85)   // a true rule

        // Ink ramp — high contrast, Swiss.
        public static let textPrimary   = Color(hex: 0x111110)   // near-black ink
        public static let textSecondary = Color(hex: 0x57554F)
        public static let textTertiary  = Color(hex: 0x8C8A83)
        public static let textDisabled  = Color(hex: 0xBDBBB3)

        // THE accent — a single confident vermilion. Everything else is ink/paper.
        public static let iris    = Color(hex: 0xF03E16)   // vermilion (the one pop)
        public static let magenta = Color(hex: 0xF03E16)
        public static let coral   = Color(hex: 0xF03E16)
        public static let amber   = Color(hex: 0xF03E16)
        public static let cyan    = Color(hex: 0x111110)   // ink (used where a 2nd colour was)
        public static let violet  = Color(hex: 0xF03E16)

        // Provenance/citations read as ink, not a second hue (keep it monochrome+1).
        public static let provenance = Color(hex: 0x111110)

        public static let success = Color(hex: 0x1F9D63)
        public static let warning = Color(hex: 0xB8791E)
        public static let danger  = Color(hex: 0xD23A28)
        public static let info    = Color(hex: 0x2F6FC4)
    }

    public enum Gradient {
        // Flat by design — the "gradients" are solid accent so legacy call sites
        // render as a clean vermilion fill, no mushy blends.
        public static let intelligence = LinearGradient(
            colors: [ColorToken.iris, ColorToken.iris], startPoint: .top, endPoint: .bottom)
        public static let aurora = LinearGradient(
            colors: [ColorToken.iris, ColorToken.iris], startPoint: .top, endPoint: .bottom)
        public static let ember = LinearGradient(
            colors: [ColorToken.iris, ColorToken.iris], startPoint: .top, endPoint: .bottom)
        public static let surfaceSheen = LinearGradient(
            colors: [.clear, .clear], startPoint: .top, endPoint: .bottom)
    }
}
