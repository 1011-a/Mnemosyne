import Foundation

/// Converts identifiers between snake_case, camelCase, kebab-case, and PascalCase for the
/// `case_style` tool. Splits the input into words on camelCase boundaries and on
/// `_ - space`, then rejoins per style. Pure + deterministic → unit-testable.
enum CaseStyle {
    /// Lowercased words extracted from any of the supported styles.
    static func words(_ s: String) -> [String] {
        let spaced = s.replacingOccurrences(of: #"([a-z0-9])([A-Z])"#, with: "$1 $2", options: .regularExpression)
        return spaced.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { $0.lowercased() }
    }

    static func toSnake(_ s: String) -> String { words(s).joined(separator: "_") }
    static func toKebab(_ s: String) -> String { words(s).joined(separator: "-") }

    static func toCamel(_ s: String) -> String {
        let w = words(s)
        guard let first = w.first else { return "" }
        return first + w.dropFirst().map(capitalize).joined()
    }

    static func toPascal(_ s: String) -> String {
        words(s).map(capitalize).joined()
    }

    static func convert(_ s: String, style: String) -> String? {
        switch style.lowercased() {
        case "snake": return toSnake(s)
        case "camel": return toCamel(s)
        case "kebab": return toKebab(s)
        case "pascal": return toPascal(s)
        default: return nil
        }
    }

    private static func capitalize(_ w: String) -> String {
        w.prefix(1).uppercased() + w.dropFirst()
    }
}
