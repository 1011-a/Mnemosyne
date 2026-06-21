import Foundation

/// Groups CSV/TSV rows by a column and aggregates another for the `csv_group_by` tool — a SQL
/// GROUP BY ("total sales by region"). Pure + deterministic → unit-testable. Pairs with
/// `DelimitedParser` and `MarkdownTable`.
enum CSVGroupBy {
    /// Group by `groupColumn`; aggregate `aggColumn` with `op` (count|sum|mean|min|max).
    /// `count` ignores aggColumn; the others require a numeric column. Result rows are sorted by
    /// the aggregate descending (ties by group name). Returns header + rows, or nil on a bad
    /// column or op.
    static func group(header: [String], rows: [[String]], groupColumn: String,
                      aggColumn: String?, op: String) -> [[String]]? {
        guard let gIdx = index(of: groupColumn, in: header) else { return nil }
        let operation = op.lowercased()
        guard ["count", "sum", "mean", "min", "max"].contains(operation) else { return nil }

        var aIdx: Int?
        if operation != "count" {
            guard let ac = aggColumn, let i = index(of: ac, in: header) else { return nil }
            aIdx = i
        }

        var counts: [String: Int] = [:]
        var values: [String: [Double]] = [:]
        var order: [String] = []
        for row in rows {
            let key = gIdx < row.count ? row[gIdx] : ""
            if counts[key] == nil { order.append(key) }
            counts[key, default: 0] += 1
            if let ai = aIdx, ai < row.count, let v = number(row[ai]) {
                values[key, default: []].append(v)
            }
        }

        var results: [(key: String, value: Double)] = []
        for key in order {
            let vals = values[key] ?? []
            let value: Double
            switch operation {
            case "count": value = Double(counts[key] ?? 0)
            case "sum": value = vals.reduce(0, +)
            case "mean": value = vals.isEmpty ? 0 : vals.reduce(0, +) / Double(vals.count)
            case "min": value = vals.min() ?? 0
            case "max": value = vals.max() ?? 0
            default: return nil
            }
            results.append((key, value))
        }
        results.sort { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }

        let aggHeader = operation == "count" ? "count" : "\(operation)(\(header[aIdx!]))"
        return [[header[gIdx], aggHeader]] + results.map { [$0.key, fmt($0.value)] }
    }

    private static func index(of name: String, in header: [String]) -> Int? {
        header.firstIndex { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    private static func number(_ s: String) -> Double? {
        Double(s.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "$", with: ""))
    }

    private static func fmt(_ v: Double) -> String {
        if v == v.rounded() { return String(Int(v)) }
        var s = String(format: "%.2f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
