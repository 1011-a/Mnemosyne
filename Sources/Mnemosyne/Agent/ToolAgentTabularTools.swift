import Foundation

/// Tabular-data tool handlers — CSV inspection/transform and JSON shaping over a stored item —
/// extracted from `ToolAgent`'s main `handleTool` switch to keep that file focused. Each resolves an
/// item, reads its chunk text, then runs a pure parser/formatter (DelimitedParser, MarkdownTable,
/// CSVSorter, the JSON helpers). Store-coupled by the resolve+read step, so they live in an
/// `extension ToolAgent` rather than migrating to Fathom. `handleTabularTool` returns nil when
/// `name` isn't one of these, letting the caller fall through.
extension ToolAgent {
    func handleTabularTool(_ name: String, args: String,
                           onStatus: @Sendable @escaping (String) -> Void) async -> (String, [Citation])? {
        func arg(_ k: String) -> String? { Self.stringArg(args, k) }
        switch name {
        case "inspect_csv":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Inspecting \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let summary = DelimitedParser.summary(text) else {
                return ("'\(it.title)' doesn't parse as CSV/TSV (no rows found).", [])
            }
            return ("'\(it.title)':\n\(summary)", [])

        case "csv_to_table":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Rendering \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            let delim = DelimitedParser.detectDelimiter(text)
            let rows = DelimitedParser.parse(text, delimiter: delim)
            guard !rows.isEmpty else { return ("'\(it.title)' has no rows to render.", []) }
            let maxRows = 30
            let clamped = Array(rows.prefix(maxRows + 1))   // header + up to maxRows data rows
            guard let table = MarkdownTable.tableFrom(clamped) else {
                return ("Couldn't render '\(it.title)' as a table.", [])
            }
            let note = rows.count > maxRows + 1 ? "\n…(\(rows.count - 1 - maxRows) more rows)" : ""
            return ("\(it.title):\n\(table)\(note)", [])

        case "csv_sort":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            guard let column = arg("column"), !column.isEmpty else { return ("Missing 'column'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Sorting \(it.title) by \(column)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            let delim = DelimitedParser.detectDelimiter(text)
            let rows = DelimitedParser.parse(text, delimiter: delim)
            guard let header = rows.first else { return ("'\(it.title)' has no rows to sort.", []) }
            func flag(_ k: String) -> Bool { (arg(k) ?? "false").lowercased() == "true" }
            guard let sorted = CSVSorter.sort(header: header, rows: Array(rows.dropFirst()), column: column,
                                              descending: flag("descending"), numeric: flag("numeric")) else {
                return ("Column '\(column)' not found in '\(it.title)'. Columns: \(header.joined(separator: ", ")).", [])
            }
            let maxRows = 30
            let clamped = Array(sorted.prefix(maxRows + 1))
            guard let table = MarkdownTable.tableFrom(clamped) else { return ("Couldn't render the sorted table.", []) }
            let note = sorted.count > maxRows + 1 ? "\n…(\(sorted.count - 1 - maxRows) more rows)" : ""
            return ("\(it.title) sorted by \(column):\n\(table)\(note)", [])

        case "csv_select":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            guard let colsArg = arg("columns"), !colsArg.isEmpty else { return ("Missing 'columns'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Selecting columns from \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            let delim = DelimitedParser.detectDelimiter(text)
            let rows = DelimitedParser.parse(text, delimiter: delim)
            guard let header = rows.first else { return ("'\(it.title)' has no rows.", []) }
            let columns = colsArg.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard let projected = CSVProjector.select(header: header, rows: Array(rows.dropFirst()), columns: columns) else {
                return ("One or more columns not found in '\(it.title)'. Columns: \(header.joined(separator: ", ")).", [])
            }
            let maxRows = 30
            let clamped = Array(projected.prefix(maxRows + 1))
            guard let table = MarkdownTable.tableFrom(clamped) else { return ("Couldn't render the selected columns.", []) }
            let note = projected.count > maxRows + 1 ? "\n…(\(projected.count - 1 - maxRows) more rows)" : ""
            return ("\(it.title) — selected columns:\n\(table)\(note)", [])

        case "csv_group_by":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            guard let groupCol = arg("group_by"), !groupCol.isEmpty else { return ("Missing 'group_by'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            let op = arg("op") ?? "count"
            onStatus("Grouping \(it.title) by \(groupCol)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            let delim = DelimitedParser.detectDelimiter(text)
            let rows = DelimitedParser.parse(text, delimiter: delim)
            guard let header = rows.first else { return ("'\(it.title)' has no rows.", []) }
            guard let grouped = CSVGroupBy.group(header: header, rows: Array(rows.dropFirst()),
                                                 groupColumn: groupCol, aggColumn: arg("aggregate"), op: op) else {
                return ("Couldn't group '\(it.title)' — check the column names and that 'aggregate' is set for \(op). Columns: \(header.joined(separator: ", ")).", [])
            }
            let maxRows = 40
            let clamped = Array(grouped.prefix(maxRows + 1))
            guard let table = MarkdownTable.tableFrom(clamped) else { return ("Couldn't render the grouped table.", []) }
            let note = grouped.count > maxRows + 1 ? "\n…(\(grouped.count - 1 - maxRows) more groups)" : ""
            return ("\(it.title) grouped by \(groupCol):\n\(table)\(note)", [])

        case "csv_dedupe":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Deduping \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            let delim = DelimitedParser.detectDelimiter(text)
            let rows = DelimitedParser.parse(text, delimiter: delim)
            guard let header = rows.first else { return ("'\(it.title)' has no rows.", []) }
            guard let (kept, removed) = CSVDedupe.dedupe(header: header, rows: Array(rows.dropFirst()), keyColumn: arg("by")) else {
                return ("Column '\(arg("by") ?? "")' not found in '\(it.title)'. Columns: \(header.joined(separator: ", ")).", [])
            }
            let maxRows = 30
            let out = [header] + kept
            guard let table = MarkdownTable.tableFrom(Array(out.prefix(maxRows + 1))) else { return ("Couldn't render the result.", []) }
            let more = out.count > maxRows + 1 ? "\n…(\(out.count - 1 - maxRows) more rows)" : ""
            return ("\(it.title) — removed \(removed) duplicate row(s), \(kept.count) remain:\n\(table)\(more)", [])

        case "csv_transpose":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Transposing \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            let delim = DelimitedParser.detectDelimiter(text)
            let rows = DelimitedParser.parse(text, delimiter: delim)
            let transposed = CSVTranspose.transpose(rows)
            guard !transposed.isEmpty, let table = MarkdownTable.tableFrom(Array(transposed.prefix(31))) else {
                return ("'\(it.title)' has no rows to transpose.", [])
            }
            let note = transposed.count > 31 ? "\n…(\(transposed.count - 31) more rows)" : ""
            return ("\(it.title) transposed:\n\(table)\(note)", [])

        case "csv_distinct":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            guard let column = arg("column"), !column.isEmpty else { return ("Missing 'column'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Finding distinct \(column) in \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            let delim = DelimitedParser.detectDelimiter(text)
            let rows = DelimitedParser.parse(text, delimiter: delim)
            guard let header = rows.first else { return ("'\(it.title)' has no rows.", []) }
            guard let values = CSVDistinct.values(header: header, rows: Array(rows.dropFirst()), column: column) else {
                return ("Column '\(column)' not found in '\(it.title)'. Columns: \(header.joined(separator: ", ")).", [])
            }
            guard !values.isEmpty else { return ("Column '\(column)' has no values.", []) }
            return ("\(values.count) distinct value(s) in '\(column)':\n" + values.prefix(100).map { "  \($0)" }.joined(separator: "\n"), [])

        case "csv_types":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Inferring column types in \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            let delim = DelimitedParser.detectDelimiter(text)
            let rows = DelimitedParser.parse(text, delimiter: delim)
            guard let header = rows.first else { return ("'\(it.title)' has no rows.", []) }
            let types = CSVTypes.infer(header: header, rows: Array(rows.dropFirst()))
            return ("Column types in '\(it.title)':\n" + types.map { "  \($0.column): \($0.type)" }.joined(separator: "\n"), [])

        case "csv_to_json":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Converting \(it.title) to JSON…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            let delim = DelimitedParser.detectDelimiter(text)
            let rows = DelimitedParser.parse(text, delimiter: delim)
            let maxRows = 100
            let clamped = Array(rows.prefix(maxRows + 1))
            guard let json = CSVConverter.toJSON(clamped) else {
                return ("'\(it.title)' has no rows to convert.", [])
            }
            let note = rows.count > maxRows + 1 ? "\n…(showing first \(maxRows) of \(rows.count - 1) rows)" : ""
            return ("\(it.title) as JSON:\n```json\n\(json)\n```\(note)", [])

        case "json_to_table":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Rendering \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let jsonRows = JSONTable.rows(from: text) else {
                return ("'\(it.title)' isn't JSON that can be tabulated (need an array of objects, an object, or an array).", [])
            }
            let maxRows = 30
            let clamped = Array(jsonRows.prefix(maxRows + 1))
            guard let table = MarkdownTable.tableFrom(clamped) else {
                return ("Couldn't render '\(it.title)' as a table.", [])
            }
            let note = jsonRows.count > maxRows + 1 ? "\n…(\(jsonRows.count - 1 - maxRows) more rows)" : ""
            return ("\(it.title):\n\(table)\(note)", [])

        case "json_to_csv":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Converting \(it.title) to CSV…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let jsonRows = JSONTable.rows(from: text) else {
                return ("'\(it.title)' isn't JSON that can be converted to CSV (need an array of objects, an object, or an array).", [])
            }
            let maxRows = 100
            let clamped = Array(jsonRows.prefix(maxRows + 1))
            guard let csv = CSVConverter.toCSV(clamped) else {
                return ("'\(it.title)' has no rows to convert.", [])
            }
            let note = jsonRows.count > maxRows + 1 ? "\n…(showing first \(maxRows) of \(jsonRows.count - 1) rows)" : ""
            return ("\(it.title) as CSV:\n```\n\(csv)\n```\(note)", [])

        case "json_keys":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Listing JSON keys in \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let paths = JSONKeys.paths(text), !paths.isEmpty else {
                return ("'\(it.title)' isn't a JSON object/array with keys.", [])
            }
            return ("\(paths.count) key path(s) in '\(it.title)':\n" + paths.map { "  \($0)" }.joined(separator: "\n"), [])

        case "json_pluck":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            guard let key = arg("key"), !key.isEmpty else { return ("Missing 'key'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Plucking \(key) from \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let values = JSONPluck.pluck(text, key: key) else {
                return ("'\(it.title)' isn't a JSON array of objects.", [])
            }
            guard !values.isEmpty else { return ("No object in '\(it.title)' has the key '\(key)'.", []) }
            return ("\(values.count) value(s) for '\(key)':\n" + values.prefix(100).map { "  \($0)" }.joined(separator: "\n"), [])

        case "json_flatten":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Flattening JSON in \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let pairs = JSONFlatten.flatten(text), !pairs.isEmpty else {
                return ("'\(it.title)' isn't JSON with values to flatten.", [])
            }
            let body = pairs.prefix(150).map { "  \($0.path) = \($0.value)" }.joined(separator: "\n")
            let more = pairs.count > 150 ? "\n  …(+\(pairs.count - 150) more)" : ""
            return ("\(pairs.count) leaf value(s) in '\(it.title)':\n\(body)\(more)", [])

        case "json_filter":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            guard let predicate = arg("where"), !predicate.isEmpty else { return ("Missing 'where' predicate.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Filtering JSON in \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            switch JSONFilter.filter(text, where: predicate) {
            case .badJSON:
                return ("'\(it.title)' isn't a JSON array/object that can be filtered.", [])
            case .badPredicate:
                return ("Couldn't parse '\(predicate)'. Use 'key OP value', e.g. 'score >= 80'.", [])
            case .noColumn(let cols):
                return ("Key not found in '\(it.title)'. Keys: \(cols.joined(separator: ", ")).", [])
            case .ok(let rows):
                guard rows.count > 1 else { return ("No objects in '\(it.title)' match '\(predicate)'.", []) }
                guard let table = MarkdownTable.tableFrom(Array(rows.prefix(31))) else { return ("Couldn't render the result.", []) }
                let note = rows.count > 31 ? "\n…(\(rows.count - 31) more rows)" : ""
                return ("\(rows.count - 1) match(es) in '\(it.title)' for '\(predicate)':\n\(table)\(note)", [])
            }

        case "csv_column_stats":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            guard let column = arg("column"), !column.isEmpty else { return ("Missing 'column'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Analyzing \(column) in \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            let delim = DelimitedParser.detectDelimiter(text)
            let rows = DelimitedParser.parse(text, delimiter: delim)
            guard let header = rows.first else { return ("'\(it.title)' has no rows to analyze.", []) }
            guard let report = ColumnAnalyzer.report(headers: header, rows: Array(rows.dropFirst()), column: column) else {
                return ("Column '\(column)' not found in '\(it.title)'. Columns: \(header.joined(separator: ", ")).", [])
            }
            return ("\(it.title) — \(report)", [])

        case "csv_filter":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            guard let predicate = arg("where"), !predicate.isEmpty else { return ("Missing 'where' predicate.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Filtering \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            let delim = DelimitedParser.detectDelimiter(text)
            let rows = DelimitedParser.parse(text, delimiter: delim)
            guard let header = rows.first else { return ("'\(it.title)' has no rows to filter.", []) }
            let data = Array(rows.dropFirst())
            switch RowFilter.evaluate(headers: header, rows: data, expr: predicate) {
            case .badPredicate:
                return ("Couldn't parse the predicate '\(predicate)'. Use 'column OP value', e.g. 'amount >= 500' or 'status = open'.", [])
            case .noColumn(let cols):
                return ("Column not found in '\(it.title)'. Columns: \(cols.joined(separator: ", ")).", [])
            case .ok(_, let matchedRows):
                guard !matchedRows.isEmpty else {
                    return ("No rows in '\(it.title)' match '\(predicate)' (of \(data.count) rows).", [])
                }
                let preview = matchedRows.prefix(10).map { "  " + $0.joined(separator: " | ") }
                let more = matchedRows.count > 10 ? ["  …(+\(matchedRows.count - 10) more rows)"] : []
                let body = ("[" + header.joined(separator: " | ") + "]\n" + (preview + more).joined(separator: "\n"))
                return ("\(matchedRows.count) of \(data.count) rows in '\(it.title)' match '\(predicate)':\n\(body)", [])
            }

        case "inspect_json":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Inspecting JSON in \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let shape = JSONInspector.shape(text) else {
                return ("'\(it.title)' doesn't parse as JSON.", [])
            }
            return ("JSON shape of '\(it.title)':\n\(shape)", [])

        case "json_value":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            guard let path = arg("path"), !path.isEmpty else { return ("Missing 'path'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Reading \(path) from \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            switch JSONPath.query(text, path: path) {
            case .badJSON: return ("'\(it.title)' doesn't parse as JSON.", [])
            case .badPath: return ("Couldn't parse the path '\(path)'. Use dot/bracket syntax like 'address.city' or 'items[0].id'.", [])
            case .notFound: return ("No value at '\(path)' in '\(it.title)' (missing key or out-of-range index). Try inspect_json to see the structure.", [])
            case .found(let value): return ("\(path) = \(value)", [])
            }

        default:
            return nil
        }
    }
}
