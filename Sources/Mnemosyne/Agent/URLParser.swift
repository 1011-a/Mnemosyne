import Foundation

/// Breaks a URL into its parts for the `parse_url` tool — scheme, host, path, decoded query
/// parameters, and fragment ("what does this tracking link contain?"). Distinct from
/// `extract_links` (which finds links). Pure + deterministic → unit-testable.
enum URLParser {
    struct Parts: Equatable {
        let scheme: String?
        let host: String?
        let path: String
        let params: [(key: String, value: String)]
        let fragment: String?

        static func == (a: Parts, b: Parts) -> Bool {
            a.scheme == b.scheme && a.host == b.host && a.path == b.path && a.fragment == b.fragment
                && a.params.map(\.key) == b.params.map(\.key) && a.params.map(\.value) == b.params.map(\.value)
        }
    }

    static func parse(_ s: String) -> Parts? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, var comps = URLComponents(string: trimmed) else { return nil }
        // Bare "example.com/path" parses as all-path — retry with an https:// scheme.
        if comps.scheme == nil, comps.host == nil {
            guard let retry = URLComponents(string: "https://" + trimmed), retry.host != nil else { return nil }
            comps = retry
        }
        guard comps.host != nil || comps.scheme != nil else { return nil }
        let params = comps.queryItems?.map { (key: $0.name, value: $0.value ?? "") } ?? []
        return Parts(scheme: comps.scheme, host: comps.host, path: comps.path, params: params, fragment: comps.fragment)
    }

    static func summary(_ s: String) -> String? {
        guard let p = parse(s) else { return nil }
        var lines: [String] = []
        if let scheme = p.scheme { lines.append("scheme: \(scheme)") }
        if let host = p.host { lines.append("host: \(host)") }
        if !p.path.isEmpty { lines.append("path: \(p.path)") }
        if !p.params.isEmpty {
            lines.append("params:\n" + p.params.map { "  \($0.key) = \($0.value)" }.joined(separator: "\n"))
        }
        if let fragment = p.fragment { lines.append("fragment: \(fragment)") }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
