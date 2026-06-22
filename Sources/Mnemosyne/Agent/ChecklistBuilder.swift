import Foundation

/// Turns a list of lines into a markdown CHECKLIST for the `make_checklist` tool — convert
/// notes or extracted action items into `- [ ]` tasks. Strips an existing list bullet / number
/// and preserves a `[x]` done-state. Pure + deterministic → unit-testable. The write-side
/// counterpart to `ChecklistAnalyzer` (which reads checklists).
enum ChecklistBuilder {
    static func build(_ data: String) -> String? {
        var out: [String] = []
        for raw in data.components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            // Strip a leading list bullet ("- ", "* ", "+ ") or a number ("1. ", "2) ").
            if let m = line.range(of: #"^[-*+]\s+"#, options: .regularExpression) {
                line.removeSubrange(m)
            } else if let m = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                line.removeSubrange(m)
            }

            // Detect + strip an existing checkbox, preserving done-state.
            var done = false
            if let m = line.range(of: #"^\[([ xX])\]\s*"#, options: .regularExpression) {
                done = line[m].contains("x") || line[m].contains("X")
                line.removeSubrange(m)
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { out.append("- [\(done ? "x" : " ")] \(trimmed)") }
        }
        return out.isEmpty ? nil : out.joined(separator: "\n")
    }
}
