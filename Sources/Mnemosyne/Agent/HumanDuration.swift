import Foundation

/// Converts between seconds and human-readable durations for the `duration` tool — "how long
/// is 3661 seconds?" → "1h 1m 1s", or "1h 30m" / "1:30:00" → seconds. Pure + deterministic →
/// unit-testable. (Named `HumanDuration` to avoid Swift's built-in `Duration`.)
enum HumanDuration {
    /// Break a second count into `d h m s`, showing only non-zero parts (sign preserved).
    static func humanize(_ total: Int) -> String {
        guard total != 0 else { return "0s" }
        var s = abs(total)
        let d = s / 86400; s %= 86400
        let h = s / 3600; s %= 3600
        let m = s / 60; let sec = s % 60
        var parts: [String] = []
        if d > 0 { parts.append("\(d)d") }
        if h > 0 { parts.append("\(h)h") }
        if m > 0 { parts.append("\(m)m") }
        if sec > 0 { parts.append("\(sec)s") }
        return (total < 0 ? "-" : "") + parts.joined(separator: " ")
    }

    /// Parse "1h 30m 15s" / "90m" / "2d", or a colon form "MM:SS" / "HH:MM:SS", into seconds.
    static func parse(_ str: String) -> Int? {
        let s = str.trimmingCharacters(in: .whitespaces).lowercased()
        guard !s.isEmpty else { return nil }

        if s.contains(":") {
            let parts = s.split(separator: ":").map { Int($0) }
            guard parts.allSatisfy({ $0 != nil }) else { return nil }
            let n = parts.map { $0! }
            switch n.count {
            case 2: return n[0] * 60 + n[1]
            case 3: return n[0] * 3600 + n[1] * 60 + n[2]
            default: return nil
            }
        }

        let units: [Character: Int] = ["d": 86400, "h": 3600, "m": 60, "s": 1]
        guard let re = try? NSRegularExpression(pattern: #"(\d+)\s*([dhms])"#) else { return nil }
        let ns = s as NSString
        var total = 0, matched = false
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            guard let val = Int(ns.substring(with: m.range(at: 1))),
                  let unit = ns.substring(with: m.range(at: 2)).first, let mult = units[unit] else { continue }
            total += val * mult
            matched = true
        }
        return matched ? total : nil
    }
}
