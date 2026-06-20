import Foundation

/// Turns an iCalendar (`.ics`) file — one or many VEVENTs — into readable,
/// searchable text so calendar events become knowledge ("when is the dentist?").
/// Pure and dependency-free; `parse` is unit-testable on a raw string.
enum ICalExtractor {
    static func extract(_ url: URL) throws -> String {
        let text = try String(contentsOf: url, encoding: .utf8)
        return parse(text)
    }

    /// Parse iCalendar text into a human line per VEVENT, blank-line separated.
    static func parse(_ raw: String) -> String {
        let lines = ContentLine.unfold(raw)
        var events: [[String: String]] = []
        var current: [String: String]? = nil
        for line in lines {
            let upper = line.uppercased()
            if upper.hasPrefix("BEGIN:VEVENT") { current = [:]; continue }
            if upper.hasPrefix("END:VEVENT") {
                if let c = current, !c.isEmpty { events.append(c) }
                current = nil; continue
            }
            guard current != nil, let (name, value) = ContentLine.property(line) else { continue }
            current?[name] = value          // last value wins
        }
        return events.map(render).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private static func render(_ e: [String: String]) -> String {
        var parts: [String] = []
        if let summary = e["SUMMARY"], !summary.isEmpty { parts.append(summary) }

        let start = e["DTSTART"].map(formatDate)
        let end = e["DTEND"].map(formatDate)
        switch (start, end) {
        case let (s?, en?): parts.append("\(s) – \(en)")
        case let (s?, _):   parts.append(s)
        default: break
        }

        if let loc = e["LOCATION"], !loc.isEmpty { parts.append("at \(loc)") }
        if let org = e["ORGANIZER"] { parts.append("organizer: \(cleanContact(org))") }
        if let desc = e["DESCRIPTION"], !desc.isEmpty { parts.append(desc) }
        return parts.joined(separator: " · ")
    }

    /// "20260615T140000Z" → "Jun 15, 2026, 14:00"; "20260615" → "Jun 15, 2026".
    /// Locale-independent so it's deterministic in tests.
    static func formatDate(_ value: String) -> String {
        let s = value.hasSuffix("Z") ? String(value.dropLast()) : value
        let segs = s.split(separator: "T", maxSplits: 1)
        guard let d = segs.first, d.count == 8,
              let y = Int(d.prefix(4)),
              let mo = Int(d.dropFirst(4).prefix(2)),
              let day = Int(d.dropFirst(6).prefix(2)),
              (1...12).contains(mo), (1...31).contains(day)
        else { return value }
        let months = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]
        var out = "\(months[mo - 1]) \(day), \(y)"
        if segs.count > 1, segs[1].count >= 4,
           let h = Int(segs[1].prefix(2)), let mi = Int(segs[1].dropFirst(2).prefix(2)) {
            out += String(format: ", %02d:%02d", h, mi)
        }
        return out
    }

    /// "MAILTO:jane@x.com" → "jane@x.com".
    private static func cleanContact(_ v: String) -> String {
        v.replacingOccurrences(of: "MAILTO:", with: "", options: .caseInsensitive)
    }
}
