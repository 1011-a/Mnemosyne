import Foundation

/// Day-of-week for a calendar date for the `weekday` tool — "what day was/is 2026-06-22?".
/// Uses Zeller's congruence so it's fully pure + deterministic (no `Date`/timezone/locale, no
/// reliance on the current clock). Proleptic Gregorian calendar. Unit-testable.
enum Weekday {
    private static let names = ["Saturday", "Sunday", "Monday", "Tuesday",
                               "Wednesday", "Thursday", "Friday"]   // Zeller h: 0=Sat … 6=Fri

    /// Day name for a Y-M-D date, or nil if the date is invalid.
    static func of(year: Int, month: Int, day: Int) -> String? {
        guard month >= 1, month <= 12, day >= 1, day <= daysIn(month: month, year: year) else { return nil }
        // Zeller treats Jan/Feb as months 13/14 of the previous year.
        var m = month, y = year
        if m < 3 { m += 12; y -= 1 }
        let k = y % 100
        let j = y / 100
        let h = (day + (13 * (m + 1)) / 5 + k + k / 4 + j / 4 + 5 * j) % 7
        return names[(h % 7 + 7) % 7]
    }

    /// Parse "YYYY-MM-DD" and return the day name, or nil if malformed/invalid.
    static func of(_ dateString: String) -> String? {
        let parts = dateString.trimmingCharacters(in: .whitespaces).split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        return of(year: y, month: m, day: d)
    }

    private static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: return isLeap(year) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    private static func isLeap(_ y: Int) -> Bool {
        (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
    }
}
