import Foundation

/// Filters the rows of a parsed CSV/TSV sheet by a simple predicate — powers the
/// `csv_filter` tool so the agent can pull the exact records a question is about
/// ("rows where status = open", "amount >= 500", "name contains da"). Pure +
/// deterministic → unit-testable. Pairs with `DelimitedParser` (rows) and reuses
/// `ColumnAnalyzer.numeric` for number-aware comparisons.
enum RowFilter {
    enum Op: String, CaseIterable {
        case ge = ">=", le = "<=", ne = "!=", eq = "=", gt = ">", lt = "<", contains = "contains"
    }

    struct Predicate: Equatable {
        let column: String
        let op: Op
        let value: String
    }

    enum Result {
        case ok(Predicate, [[String]])
        case badPredicate
        case noColumn([String])   // carries the available column names for a helpful error
    }

    /// Multi-character operators must be tried before their single-char prefixes
    /// (`>=` before `>`, `!=` before `=`). `contains` is matched as a keyword separately.
    private static let scanOrder: [Op] = [.ge, .le, .ne, .eq, .gt, .lt]

    static func parse(_ expr: String) -> Predicate? {
        let s = expr.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        // `column contains value` (case-insensitive keyword, surrounded by whitespace).
        if let r = s.range(of: #"\s+contains\s+"#, options: [.regularExpression, .caseInsensitive]) {
            let col = String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            let val = unquote(String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces))
            return col.isEmpty || val.isEmpty ? nil : Predicate(column: col, op: .contains, value: val)
        }
        for op in scanOrder {
            guard let r = s.range(of: op.rawValue) else { continue }
            let col = String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            let val = unquote(String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces))
            if !col.isEmpty, !val.isEmpty { return Predicate(column: col, op: op, value: val) }
        }
        return nil
    }

    /// Does one cell satisfy `op value`? Numeric when both sides parse as numbers (so
    /// `500` == `500.0` and `>` orders numerically); otherwise case-insensitive string.
    static func matches(cell: String, op: Op, value: String) -> Bool {
        let c = cell.trimmingCharacters(in: .whitespaces)
        switch op {
        case .contains:
            return c.range(of: value, options: .caseInsensitive) != nil
        case .eq, .ne:
            let equal: Bool
            if let a = ColumnAnalyzer.numeric(c), let b = ColumnAnalyzer.numeric(value) { equal = a == b }
            else { equal = c.caseInsensitiveCompare(value) == .orderedSame }
            return op == .eq ? equal : !equal
        case .gt, .lt, .ge, .le:
            if let a = ColumnAnalyzer.numeric(c), let b = ColumnAnalyzer.numeric(value) {
                switch op {
                case .gt: return a > b
                case .lt: return a < b
                case .ge: return a >= b
                case .le: return a <= b
                default: return false
                }
            }
            let r = c.compare(value)
            switch op {
            case .gt: return r == .orderedDescending
            case .lt: return r == .orderedAscending
            case .ge: return r != .orderedAscending
            case .le: return r != .orderedDescending
            default: return false
            }
        }
    }

    static func evaluate(headers: [String], rows: [[String]], expr: String) -> Result {
        guard let p = parse(expr) else { return .badPredicate }
        guard let idx = headers.firstIndex(where: { $0.caseInsensitiveCompare(p.column) == .orderedSame })
        else { return .noColumn(headers) }
        let matched = rows.filter { $0.indices.contains(idx) && matches(cell: $0[idx], op: p.op, value: p.value) }
        return .ok(p, matched)
    }

    private static func unquote(_ s: String) -> String {
        guard s.count >= 2 else { return s }
        let pairs: [(Character, Character)] = [("\"", "\""), ("'", "'")]
        for (open, close) in pairs where s.first == open && s.last == close {
            return String(s.dropFirst().dropLast())
        }
        return s
    }
}
