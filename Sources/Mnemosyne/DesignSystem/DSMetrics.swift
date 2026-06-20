import SwiftUI

// MARK: - Spacing, radius, typography, motion, elevation tokens

extension DS {
    /// 4-pt base grid. Reference by name, never by literal.
    public enum Space {
        public static let x0: CGFloat = 0
        public static let x1: CGFloat = 4
        public static let x2: CGFloat = 8
        public static let x3: CGFloat = 12
        public static let x4: CGFloat = 16
        public static let x5: CGFloat = 20
        public static let x6: CGFloat = 24
        public static let x8: CGFloat = 32
        public static let x10: CGFloat = 40
        public static let x12: CGFloat = 48
        public static let x16: CGFloat = 64
    }

    public enum Radius {
        public static let sm: CGFloat = 6
        public static let md: CGFloat = 10
        public static let lg: CGFloat = 14
        public static let xl: CGFloat = 20
        public static let xxl: CGFloat = 28
        public static let pill: CGFloat = 999
    }

    /// Type ramp — three voices by FUNCTION, smaller & tighter overall:
    ///  • serif (New York) for the editorial content voice — the hero & answer lead
    ///  • sans (grotesk) for all UI chrome — nav, titles, body, labels, buttons
    ///  • monospaced for data — metric values, code, file paths
    public enum Typo {
        // Editorial serif — the AI's content voice.
        public static let hero    = Font.system(size: 46, weight: .bold,      design: .serif)
        public static let display = Font.system(size: 33, weight: .bold,      design: .serif)
        public static let lead    = Font.system(size: 18, weight: .semibold,  design: .serif)

        // UI sans — chrome & reading text.
        public static let title1  = Font.system(size: 25, weight: .bold,      design: .default)
        public static let title2  = Font.system(size: 18, weight: .semibold,  design: .default)
        public static let title3  = Font.system(size: 14.5, weight: .semibold, design: .default)
        public static let body    = Font.system(size: 13.5, weight: .regular, design: .default)
        public static let bodyMed = Font.system(size: 13.5, weight: .medium,  design: .default)
        public static let callout = Font.system(size: 12, weight: .regular,   design: .default)
        public static let caption = Font.system(size: 10.5, weight: .semibold, design: .default)

        // Monospaced — data, numbers, code, paths.
        public static let mono      = Font.system(size: 11, weight: .regular,  design: .monospaced)
        public static let statValue = Font.system(size: 19, weight: .semibold, design: .monospaced)
        public static let statBig   = Font.system(size: 24, weight: .semibold, design: .monospaced)
    }

    /// Spring + duration tokens. AI surfaces should feel alive but never jittery.
    public enum Motion {
        public static let snappy = Animation.spring(response: 0.30, dampingFraction: 0.82)
        public static let smooth = Animation.spring(response: 0.45, dampingFraction: 0.85)
        public static let bounce = Animation.spring(response: 0.50, dampingFraction: 0.62)
        public static let fast   = Animation.easeOut(duration: 0.12)
        public static let base   = Animation.easeInOut(duration: 0.22)
    }

    /// Elevation = shadow + (optionally) a material. Higher tokens float more.
    public struct Shadow: Sendable {
        public let color: Color
        public let radius: CGFloat
        public let x: CGFloat
        public let y: CGFloat
    }

    // Swiss/flat: separation comes from hairlines & whitespace, not shadow.
    // Shadows are barely-there, neutral grey.
    public enum Elevation {
        public static let e1 = Shadow(color: Color(hex: 0x111110).opacity(0.04), radius: 4,  x: 0, y: 1)
        public static let e2 = Shadow(color: Color(hex: 0x111110).opacity(0.06), radius: 10, x: 0, y: 3)
        public static let e3 = Shadow(color: Color(hex: 0x111110).opacity(0.10), radius: 24, x: 0, y: 10)
        public static let glow = Shadow(color: Color(hex: 0x111110).opacity(0.06), radius: 10, x: 0, y: 3)
    }
}

extension View {
    /// Apply an elevation shadow token.
    public func dsShadow(_ s: DS.Shadow) -> some View {
        shadow(color: s.color, radius: s.radius, x: s.x, y: s.y)
    }
}
