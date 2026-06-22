import Foundation

/// Word-wraps text to a column width for the `wrap_text` tool — reflow prose/comments to N
/// columns, preserving blank-line paragraph breaks. Words longer than the width stay whole on
/// their own line. Pure + deterministic → unit-testable.
enum TextWrap {
    static func wrap(_ text: String, width: Int) -> String {
        guard width > 0 else { return text }
        return text.components(separatedBy: "\n\n")
            .map { wrapParagraph($0, width: width) }
            .joined(separator: "\n\n")
    }

    private static func wrapParagraph(_ para: String, width: Int) -> String {
        let words = para.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }).map(String.init)
        guard !words.isEmpty else { return "" }
        var lines: [String] = []
        var current = ""
        for w in words {
            if current.isEmpty {
                current = w
            } else if current.count + 1 + w.count <= width {
                current += " " + w
            } else {
                lines.append(current)
                current = w
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.joined(separator: "\n")
    }
}
