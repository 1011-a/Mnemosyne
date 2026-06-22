import Foundation

/// Infers the type of each CSV/TSV column for the `csv_types` tool — number, boolean, date,
/// text, or empty — by checking all the column's non-empty values. A quick schema view. Pure +
/// deterministic → unit-testable. Pairs with `DelimitedParser`.
enum CSVTypes {
    static func infer(header: [String], rows: [[String]]) -> [(column: String, type: String)] {
        header.enumerated().map { idx, name in
            let values = rows.compactMap { idx < $0.count ? $0[idx].trimmingCharacters(in: .whitespaces) : nil }
                .filter { !$0.isEmpty }
            return (name, type(of: values))
        }
    }

    static func type(of values: [String]) -> String {
        guard !values.isEmpty else { return "empty" }
        if values.allSatisfy({ Double($0.replacingOccurrences(of: ",", with: "")) != nil }) { return "number" }
        let bools: Set<String> = ["true", "false", "yes", "no"]
        if values.allSatisfy({ bools.contains($0.lowercased()) }) { return "boolean" }
        if values.allSatisfy(isDate) { return "date" }
        return "text"
    }

    private static func isDate(_ s: String) -> Bool {
        s.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
            || s.range(of: #"^\d{1,2}/\d{1,2}/\d{2,4}$"#, options: .regularExpression) != nil
    }
}
