import Foundation

/// Turns a `.webloc` bookmark (a plist with a `URL` key, as Safari/Finder save
/// dragged links) into searchable text: the URL plus its host and slug words, so
/// a saved link is findable by its domain or title words ("bake bread"), not just
/// an opaque address. Pure; `parse` is unit-testable on raw plist `Data`.
enum WebLocExtractor {
    static func extract(_ url: URL) throws -> String {
        try parse(Data(contentsOf: url)) ?? ""
    }

    /// Read the `URL` value from webloc plist data and expand it. nil if not a
    /// plist or it has no URL.
    static func parse(_ data: Data) -> String? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any] else { return nil }
        let raw = (dict["URL"] as? String) ?? (dict["url"] as? String)
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return readable(raw.trimmingCharacters(in: .whitespaces))
    }

    /// "https://example.com/how-to-bake-bread" →
    /// "https://example.com/how-to-bake-bread\nexample.com how to bake bread"
    static func readable(_ urlString: String) -> String {
        guard let u = URL(string: urlString), let host = u.host else { return urlString }
        let slug = u.pathComponents
            .filter { $0 != "/" && !$0.isEmpty }
            .joined(separator: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".html", with: "")
            .trimmingCharacters(in: .whitespaces)
        let words = [host, slug].filter { !$0.isEmpty }.joined(separator: " ")
        return words.isEmpty ? urlString : "\(urlString)\n\(words)"
    }
}
