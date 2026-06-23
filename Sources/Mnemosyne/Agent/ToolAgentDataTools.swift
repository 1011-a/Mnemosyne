import Foundation
import Fathom

/// JSON-string / list / date / markdown utility tool handlers, extracted from `ToolAgent`'s main
/// `handleTool` switch to keep that file focused. Pure value-in/value-out (no store/network/UI;
/// distinct from the store-based csv_*/json-on-item tools, which stay in the main file because they
/// read ingested items). `handleDataTool` returns nil when `name` isn't one of these.
extension ToolAgent {
    func handleDataTool(_ name: String, args: String) -> (String, [Citation])? {
        func arg(_ k: String) -> String? { Self.stringArg(args, k) }
        switch name {
        case "extract_json":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            let blocks = EmbeddedJSON.candidates(text)
            guard !blocks.isEmpty else { return ("No valid JSON found in the text.", []) }
            let body = blocks.map { "```json\n\($0)\n```" }.joined(separator: "\n\n")
            return ("Found \(blocks.count) JSON block(s):\n\(body)", [])

        case "format_json":
            guard let json = arg("json"), !json.isEmpty else { return ("Missing 'json'.", []) }
            let minify = (arg("mode") ?? "pretty").lowercased() == "minify"
            guard let out = minify ? JSONFormatter.minify(json) : JSONFormatter.pretty(json) else {
                return ("That isn't valid JSON (needs a top-level object or array).", [])
            }
            return ("```json\n\(out)\n```", [])

        case "json_merge":
            guard let a = arg("a"), !a.isEmpty, let b = arg("b"), !b.isEmpty else { return ("Need both 'a' and 'b' JSON objects.", []) }
            let deep = (arg("deep") ?? "true").lowercased() != "false"
            guard let merged = JSONMerge.merge(a, b, deep: deep) else {
                return ("Both 'a' and 'b' must be JSON objects ({...}).", [])
            }
            return ("```json\n\(merged)\n```", [])

        case "sort_lines":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            func flag(_ k: String) -> Bool { (arg(k) ?? "false").lowercased() == "true" }
            let sorted = LineSorter.sort(text, descending: flag("descending"),
                                         unique: flag("unique"), numeric: flag("numeric"))
            guard !sorted.isEmpty else { return ("No non-blank lines to sort.", []) }
            return (sorted, [])

        case "compare_lists":
            guard let a = arg("a"), let b = arg("b") else { return ("Missing 'a' or 'b'.", []) }
            let mode = arg("mode") ?? "common"
            guard let result = ListOps.compare(a, b, op: mode) else {
                return ("Unknown mode. Use 'common', 'only_a', 'only_b', or 'union'.", [])
            }
            guard !result.isEmpty else { return ("No items in the '\(mode)' result.", []) }
            return ("\(result.count) item(s) (\(mode)):\n" + result.map { "  \($0)" }.joined(separator: "\n"), [])

        case "strip_markdown":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            let plain = Fathom.MarkdownStripper.strip(text).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !plain.isEmpty else { return ("Nothing left after stripping markdown.", []) }
            return (plain, [])

        case "weekday":
            guard let date = arg("date"), !date.isEmpty else { return ("Missing 'date' (YYYY-MM-DD).", []) }
            guard let day = Weekday.of(date) else {
                return ("'\(date)' isn't a valid date — use YYYY-MM-DD.", [])
            }
            return ("\(date) is a \(day).", [])

        case "date_diff":
            guard let from = arg("from"), !from.isEmpty else { return ("Missing 'from' date (YYYY-MM-DD).", []) }
            let to = arg("to").flatMap { $0.isEmpty ? nil : $0 } ?? DateMath.todayISO(Date())
            guard let days = DateMath.daysBetween(from: from, to: to) else {
                return ("Couldn't parse the dates — use YYYY-MM-DD.", [])
            }
            return (DateMath.phrase(days, from: from, to: to), [])

        case "add_days":
            guard let date = arg("date"), !date.isEmpty else { return ("Missing 'date' (YYYY-MM-DD).", []) }
            guard let n = Int(arg("days") ?? "") else { return ("Missing or invalid 'days' (an integer).", []) }
            guard let result = DateMath.addDays(to: date, days: n) else {
                return ("Couldn't parse '\(date)' — use YYYY-MM-DD.", [])
            }
            let weekday = DateMath.weekday(result).map { " (\($0))" } ?? ""
            return ("\(date) + \(n) day\(abs(n) == 1 ? "" : "s") = \(result)\(weekday)", [])

        case "make_table":
            guard let data = arg("data"), !data.isEmpty else { return ("Missing 'data' (rows of cells).", []) }
            guard let table = MarkdownTable.make(data) else {
                return ("Couldn't build a table from the data. Pass newline-separated rows with comma- or pipe-separated cells.", [])
            }
            return (table, [])

        default:
            return nil
        }
    }
}
