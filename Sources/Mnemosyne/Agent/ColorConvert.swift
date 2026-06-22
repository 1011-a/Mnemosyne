import Foundation

/// Converts between hex and RGB colors for the `color` tool — '#FF5733' ↔ 'rgb(255, 87, 51)'.
/// Direction is auto-detected (a comma means RGB input). Pure + deterministic → unit-testable.
enum ColorConvert {
    /// Parse '#FF5733' / 'FF5733' / '#fff' into (r, g, b); nil if not 3/6 hex digits.
    static func hexToRGB(_ hex: String) -> (r: Int, g: Int, b: Int)? {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }   // expand shorthand
        guard h.count == 6, let v = Int(h, radix: 16) else { return nil }
        return ((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF)
    }

    /// '#RRGGBB' for 0–255 components; nil if any is out of range.
    static func rgbToHex(_ r: Int, _ g: Int, _ b: Int) -> String? {
        guard [r, g, b].allSatisfy({ (0...255).contains($0) }) else { return nil }
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// Auto-convert: a comma → RGB input → hex; otherwise hex input → rgb(). Nil if invalid.
    static func describe(_ input: String) -> String? {
        let s = input.trimmingCharacters(in: .whitespaces)
        if s.contains(",") {
            let nums = s.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            guard nums.count == 3, let hex = rgbToHex(nums[0], nums[1], nums[2]) else { return nil }
            return "rgb(\(nums[0]), \(nums[1]), \(nums[2])) = \(hex)"
        }
        guard let (r, g, b) = hexToRGB(s), let hex = rgbToHex(r, g, b) else { return nil }
        return "\(hex) = rgb(\(r), \(g), \(b))"
    }
}
