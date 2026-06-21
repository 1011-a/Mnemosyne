import Foundation

/// Pulls #hashtags and @mentions out of a document for the `extract_mentions` tool — many
/// note-takers tag with `#project` / `@person`. Pure + deterministic → unit-testable.
///
/// Each sigil must sit at the start or after whitespace, which excludes emails (`a@b.com` —
/// the `@` follows a letter) and markdown headings (`# Heading` — a space follows the `#`).
/// Names are matched case-insensitively and lowercased for counting.
enum HashtagExtractor {
    struct Result: Equatable {
        let hashtags: [(name: String, count: Int)]
        let mentions: [(name: String, count: Int)]

        static func == (a: Result, b: Result) -> Bool {
            a.hashtags.map(\.name) == b.hashtags.map(\.name) && a.hashtags.map(\.count) == b.hashtags.map(\.count)
                && a.mentions.map(\.name) == b.mentions.map(\.name) && a.mentions.map(\.count) == b.mentions.map(\.count)
        }
    }

    static func extract(_ text: String) -> Result {
        Result(hashtags: counts(of: "#", in: text), mentions: counts(of: "@", in: text))
    }

    private static func counts(of sigil: String, in text: String) -> [(name: String, count: Int)] {
        guard !text.isEmpty,
              let re = try? NSRegularExpression(pattern: #"(?:^|\s)\#(sigil)([A-Za-z][A-Za-z0-9_]+)"#)
        else { return [] }
        let ns = text as NSString
        var freq: [String: Int] = [:]
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1)).lowercased()
            freq[name, default: 0] += 1
        }
        return freq.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { (name: $0.key, count: $0.value) }
    }

    static func summary(_ text: String) -> String? {
        let r = extract(text)
        guard !r.hashtags.isEmpty || !r.mentions.isEmpty else { return nil }
        var parts: [String] = []
        if !r.hashtags.isEmpty {
            parts.append("Hashtags: " + r.hashtags.map { "#\($0.name) (\($0.count))" }.joined(separator: ", "))
        }
        if !r.mentions.isEmpty {
            parts.append("Mentions: " + r.mentions.map { "@\($0.name) (\($0.count))" }.joined(separator: ", "))
        }
        return parts.joined(separator: "\n")
    }
}
