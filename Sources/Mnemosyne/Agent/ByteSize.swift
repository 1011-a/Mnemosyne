import Foundation

/// Converts between byte counts and human-readable sizes for the `file_size` tool — "how big
/// is 1500000 bytes?" → "1.5 MB", or "1.5 MB" / "2GB" → bytes. Decimal (1000-based, like the
/// macOS Finder). Pure + deterministic → unit-testable.
enum ByteSize {
    private static let units = ["B", "KB", "MB", "GB", "TB", "PB"]

    static func humanize(_ bytes: Int) -> String {
        var size = Double(abs(bytes))
        var i = 0
        while size >= 1000, i < units.count - 1 { size /= 1000; i += 1 }
        let sign = bytes < 0 ? "-" : ""
        let str = size == size.rounded() ? String(Int(size)) : String(format: "%.1f", size)
        return "\(sign)\(str) \(units[i])"
    }

    /// Parse "1.5 MB" / "500 B" / "2GB" (unit optional → bytes) into a byte count; nil if invalid.
    static func parse(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces).uppercased()
        guard let re = try? NSRegularExpression(pattern: #"^([0-9]*\.?[0-9]+)\s*(B|KB|MB|GB|TB|PB)?$"#) else { return nil }
        let ns = t as NSString
        guard let m = re.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)),
              let num = Double(ns.substring(with: m.range(at: 1))) else { return nil }
        let unit = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : "B"
        guard let idx = units.firstIndex(of: unit) else { return nil }
        let mult = pow(1000.0, Double(idx))
        return Int((num * mult).rounded())
    }
}
