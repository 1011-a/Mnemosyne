import Foundation

/// Date arithmetic for the `date_diff` tool — days between two dates, or until a deadline.
/// Parsing + the day count are pure + deterministic (fixed formats, UTC) → unit-testable;
/// only "today" is read in the tool handler.
enum DateMath {
    /// A UTC Gregorian calendar so day counts don't shift with the local time zone / DST.
    private static var utcCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    /// Parse `YYYY-MM-DD` or `YYYY/MM/DD` (UTC midnight).
    static func parse(_ s: String) -> Date? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        for format in ["yyyy-MM-dd", "yyyy/MM/dd"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.isLenient = false   // reject out-of-range months/days like 2026-13-40
            f.dateFormat = format
            if let d = f.date(from: trimmed) { return d }
        }
        return nil
    }

    /// Signed whole days from `from` to `to` (negative if `to` is earlier); nil if unparseable.
    static func daysBetween(from: String, to: String) -> Int? {
        guard let a = parse(from), let b = parse(to) else { return nil }
        return utcCalendar.dateComponents([.day], from: a, to: b).day
    }

    /// Today's date as `YYYY-MM-DD` (UTC) — the only impure entry point.
    static func todayISO(_ now: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: now)
    }

    /// The date `days` after `dateStr` (negative = earlier) as `YYYY-MM-DD`; nil if unparseable.
    static func addDays(to dateStr: String, days: Int) -> String? {
        guard let date = parse(dateStr),
              let result = utcCalendar.date(byAdding: .day, value: days, to: date) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: result)
    }

    /// The weekday name ("Monday") for a date, or nil if unparseable.
    static func weekday(_ dateStr: String) -> String? {
        guard let date = parse(dateStr) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEEE"
        return f.string(from: date)
    }

    static func phrase(_ days: Int, from: String, to: String) -> String {
        let n = abs(days)
        let unit = n == 1 ? "day" : "days"
        if days == 0 { return "\(from) and \(to) are the same day." }
        return days > 0 ? "\(to) is \(n) \(unit) after \(from)." : "\(to) is \(n) \(unit) before \(from)."
    }
}
