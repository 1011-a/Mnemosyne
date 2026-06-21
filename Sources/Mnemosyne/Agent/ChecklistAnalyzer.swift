import Foundation

/// Analyzes a markdown CHECKLIST for the `task_progress` tool — counts done vs pending
/// boxes and reports a completion percentage. Distinct from `extract_action_items` (which
/// only surfaces the *unchecked* TODOs to act on); this reports the whole list's PROGRESS,
/// including completed items. Pure + deterministic → unit-testable.
enum ChecklistAnalyzer {
    struct Item: Equatable {
        let done: Bool
        let text: String
    }

    /// Markdown task lines: `- [ ] todo`, `* [x] done`, `+ [X] done` (any list bullet).
    static func items(_ text: String) -> [Item] {
        guard let re = try? NSRegularExpression(pattern: #"^\s*[-*+]\s*\[([ xX])\]\s*(.+?)\s*$"#) else { return [] }
        var out: [Item] = []
        for line in text.components(separatedBy: .newlines) {
            let whole = NSRange(line.startIndex..., in: line)
            guard let m = re.firstMatch(in: line, range: whole), m.numberOfRanges > 2,
                  let markRange = Range(m.range(at: 1), in: line),
                  let textRange = Range(m.range(at: 2), in: line) else { continue }
            let done = line[markRange] != " "
            let body = String(line[textRange])
            if !body.isEmpty { out.append(Item(done: done, text: body)) }
        }
        return out
    }

    /// A progress summary, or nil when the document has no checklist items. `maxList` caps
    /// each of the pending/done previews.
    static func report(_ text: String, maxList: Int = 15) -> String? {
        let all = items(text)
        guard !all.isEmpty else { return nil }
        let done = all.filter { $0.done }
        let pending = all.filter { !$0.done }
        let pct = Int((Double(done.count) / Double(all.count) * 100).rounded())

        func block(_ label: String, _ box: String, _ items: [Item]) -> String? {
            guard !items.isEmpty else { return nil }
            let shown = items.prefix(maxList).map { "  \(box) \($0.text)" }
            let more = items.count > maxList ? ["  …(+\(items.count - maxList) more)"] : []
            return "\(label):\n" + (shown + more).joined(separator: "\n")
        }

        let header = "Progress: \(done.count)/\(all.count) done (\(pct)%)."
        let parts = [block("Pending", "☐", pending), block("Done", "☑", done)].compactMap { $0 }
        return ([header] + parts).joined(separator: "\n")
    }
}
