import Foundation

/// Turns a vCard (`.vcf`) — one or many contacts — into readable, searchable text
/// so contacts become first-class knowledge ("what's Jane's email?"). Pure and
/// dependency-free; `parse` is unit-testable on a raw string.
enum VCardExtractor {
    static func extract(_ url: URL) throws -> String {
        let text = try String(contentsOf: url, encoding: .utf8)
        return parse(text)
    }

    /// Parse vCard text into a human paragraph per contact, blank-line separated.
    static func parse(_ raw: String) -> String {
        let lines = ContentLine.unfold(raw)
        var cards: [[String: [String]]] = []          // property → values, per card
        var current: [String: [String]]? = nil
        for line in lines {
            let upper = line.uppercased()
            if upper.hasPrefix("BEGIN:VCARD") { current = [:]; continue }
            if upper.hasPrefix("END:VCARD") {
                if let c = current, !c.isEmpty { cards.append(c) }
                current = nil; continue
            }
            guard current != nil, let (name, value) = ContentLine.property(line) else { continue }
            current?[name, default: []].append(value)
        }
        return cards.map(render).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    // MARK: rendering

    private static func render(_ card: [String: [String]]) -> String {
        var parts: [String] = []
        let name = card["FN"]?.first ?? card["N"].flatMap { structuredName($0.first ?? "") } ?? ""
        if !name.isEmpty { parts.append(name) }

        let org = card["ORG"]?.first?.replacingOccurrences(of: ";", with: ", ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ", "))
        let title = card["TITLE"]?.first
        switch (org, title) {
        case let (o?, t?) where !o.isEmpty && !t.isEmpty: parts.append("\(t) at \(o)")
        case let (o?, _) where !o.isEmpty:                parts.append(o)
        case let (_, t?) where !t.isEmpty:                parts.append(t)
        default: break
        }

        if let emails = card["EMAIL"], !emails.isEmpty {
            parts.append("Email: " + emails.joined(separator: ", "))
        }
        if let tels = card["TEL"], !tels.isEmpty {
            parts.append("Phone: " + tels.joined(separator: ", "))
        }
        if let adrs = card["ADR"], let adr = adrs.first.map(structuredAddress), !adr.isEmpty {
            parts.append(adr)
        }
        if let urls = card["URL"], !urls.isEmpty { parts.append(urls.joined(separator: ", ")) }
        if let bday = card["BDAY"]?.first, !bday.isEmpty { parts.append("Birthday: \(bday)") }
        if let note = card["NOTE"]?.first, !note.isEmpty { parts.append("Note: \(note)") }
        return parts.joined(separator: " · ")
    }

    /// N is "Family;Given;Additional;Prefix;Suffix" → "Prefix Given Additional Family Suffix".
    private static func structuredName(_ n: String) -> String {
        let f = n.components(separatedBy: ";")
        func at(_ i: Int) -> String { i < f.count ? f[i].trimmingCharacters(in: .whitespaces) : "" }
        return [at(3), at(1), at(2), at(0), at(4)].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// ADR is "pobox;ext;street;locality;region;postal;country".
    private static func structuredAddress(_ a: String) -> String {
        a.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: ", ")
    }

}
