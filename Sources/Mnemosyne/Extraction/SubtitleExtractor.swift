import Foundation

/// Turns a subtitle file (`.srt` / `.vtt` / `.sbv`) into clean, searchable
/// dialogue — stripping cue indices, timecodes, the WEBVTT header, and inline
/// markup. So a downloaded film/course caption becomes knowledge. Pure; `parse`
/// is unit-testable on a raw string.
enum SubtitleExtractor {
    static func isSubtitle(_ url: URL) -> Bool {
        ["srt", "vtt", "sbv"].contains(url.pathExtension.lowercased())
    }

    static func extract(_ url: URL) throws -> String {
        parse(try String(contentsOf: url, encoding: .utf8))
    }

    static func parse(_ raw: String) -> String {
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var out: [String] = []
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("WEBVTT") || line.hasPrefix("NOTE") || line.hasPrefix("STYLE") { continue }
            if line.contains("-->") { continue }       // timecode cue
            if Int(line) != nil { continue }           // bare cue index
            let cleaned = stripMarkup(line)
            if !cleaned.isEmpty, out.last != cleaned {  // drop consecutive repeats
                out.append(cleaned)
            }
        }
        return out.joined(separator: " ")
    }

    /// Remove `<i>…</i>` / `<c.color>` / `{\an8}` style inline markup.
    private static func stripMarkup(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
