import Foundation
import Fathom

/// Number / statistics tool handlers, extracted from `ToolAgent`'s main `handleTool` switch to
/// keep that file focused on knowledge/agent orchestration rather than a 4000-line god-switch.
/// Each is a pure value-in/value-out handler (no store/network/UI), so they live cleanly apart.
/// `handleNumberTool` returns nil when `name` isn't one of these tools, letting the caller fall
/// through. (These map 1:1 to future Fathom built-in `OrchestratorTool`s as the migration lands.)
extension ToolAgent {
    func handleNumberTool(_ name: String, args: String) -> (String, [Citation])? {
        func arg(_ k: String) -> String? { Self.stringArg(args, k) }
        switch name {
        case "number_stats":
            guard let data = arg("data"), !data.isEmpty else { return ("Missing 'data' (numbers).", []) }
            guard let report = NumberStats.report(data) else {
                return ("Couldn't parse any numbers from the data. Pass values separated by commas or spaces.", [])
            }
            return (report, [])

        case "sparkline":
            guard let data = arg("data"), !data.isEmpty else { return ("Missing 'data' (numbers).", []) }
            guard let spark = TextSparkline.render(data) else {
                return ("Couldn't parse any numbers from the data. Pass values separated by commas or spaces.", [])
            }
            return (spark, [])

        case "quartiles":
            guard let data = arg("data"), !data.isEmpty else { return ("Missing 'data' (numbers).", []) }
            let nums = NumberStats.parse(data)
            guard let q = Quartiles.compute(nums) else {
                return ("Couldn't parse any numbers from the data.", [])
            }
            let f = Quartiles.fmt
            return ("Q1 \(f(q.q1)), median \(f(q.q2)), Q3 \(f(q.q3)), IQR \(f(q.iqr)) (min \(f(nums.min()!)), max \(f(nums.max()!)))", [])

        case "z_score":
            guard let data = arg("data"), !data.isEmpty else { return ("Missing 'data' (numbers).", []) }
            let nums = NumberStats.parse(data)
            guard !nums.isEmpty else { return ("Couldn't parse any numbers from the data.", []) }
            if let valueStr = arg("value"), let target = Double(valueStr) {
                guard let z = ZScore.score(of: target, in: nums) else {
                    return ("Can't compute a z-score — the numbers have zero spread (all identical).", [])
                }
                return ("z = \(Quartiles.fmt((z * 1000).rounded() / 1000)) for \(Quartiles.fmt(target)) (n=\(nums.count)).", [])
            }
            guard let zs = ZScore.standardize(nums) else {
                return ("Can't standardize — the numbers have zero spread (all identical).", [])
            }
            let list = zs.map { Quartiles.fmt(($0 * 100).rounded() / 100) }.joined(separator: ", ")
            return ("z-scores: \(list)", [])

        case "percentile":
            guard let data = arg("data"), !data.isEmpty else { return ("Missing 'data' (numbers).", []) }
            let nums = NumberStats.parse(data)
            let p = Double(arg("p") ?? "") ?? 50
            guard let v = Percentile.value(nums, p: p) else {
                return ("Couldn't parse any numbers from the data.", [])
            }
            let pClamped = Swift.max(0, Swift.min(100, p))
            return ("P\(Quartiles.fmt(pClamped)) = \(Quartiles.fmt((v * 1000).rounded() / 1000)) (n=\(nums.count)).", [])

        case "histogram":
            guard let data = arg("data"), !data.isEmpty else { return ("Missing 'data' (numbers).", []) }
            let n = Swift.min(Swift.max(Int(arg("bins") ?? "") ?? 10, 1), 50)
            guard let bins = Histogram.bins(NumberStats.parse(data), count: n) else {
                return ("Couldn't parse any numbers from the data.", [])
            }
            return ("```\n\(Histogram.chart(bins))\n```", [])

        case "outliers":
            guard let data = arg("data"), !data.isEmpty else { return ("Missing 'data' (numbers).", []) }
            let k = Swift.max(Double(arg("k") ?? "") ?? 1.5, 0.1)
            guard let r = Fathom.Series.outliers(NumberStats.parse(data), k: k) else {
                return ("Need at least 4 numbers to detect outliers.", [])
            }
            let f = Quartiles.fmt
            let outs = r.low + r.high
            if outs.isEmpty {
                return ("No outliers (k=\(f(k)) fences \(f(r.lower))…\(f(r.upper))).", [])
            }
            let list = outs.map(f).joined(separator: ", ")
            return ("\(outs.count) outlier\(outs.count == 1 ? "" : "s"): \(list) (outside \(f(r.lower))…\(f(r.upper)), k=\(f(k))).", [])

        case "correlation":
            guard let xs = arg("x"), !xs.isEmpty, let ys = arg("y"), !ys.isEmpty else {
                return ("Missing 'x' and/or 'y' (two number lists).", [])
            }
            let x = NumberStats.parse(xs), y = NumberStats.parse(ys)
            guard x.count == y.count else {
                return ("x has \(x.count) numbers but y has \(y.count) — the two lists must be the same length.", [])
            }
            guard let r = Correlation.pearson(x, y) else {
                return ("Need at least 2 paired numbers, and neither list can be constant (flat).", [])
            }
            return ("r = \(Quartiles.fmt((r * 1000).rounded() / 1000)) (\(Correlation.describe(r)), n=\(x.count))", [])

        case "moving_average":
            guard let data = arg("data"), !data.isEmpty else { return ("Missing 'data' (numbers).", []) }
            let nums = NumberStats.parse(data)
            guard !nums.isEmpty else { return ("Couldn't parse any numbers from the data.", []) }
            let w = Swift.max(Int(arg("window") ?? "") ?? 3, 1)
            guard let ma = Fathom.Series.movingAverage(nums, window: w) else {
                return ("Window (\(w)) must be between 1 and the number of values (\(nums.count)).", [])
            }
            let list = ma.map { Quartiles.fmt(($0 * 100).rounded() / 100) }.joined(separator: ", ")
            return ("\(w)-point moving average (\(ma.count) values): \(list)", [])

        case "pct_change":
            guard let data = arg("data"), !data.isEmpty else { return ("Missing 'data' (numbers).", []) }
            let nums = NumberStats.parse(data)
            guard let changes = Fathom.Series.pctChange(nums) else {
                return ("Need at least 2 numbers to compute changes.", [])
            }
            let list = changes.map { c -> String in
                guard let c else { return "n/a" }
                let v = Quartiles.fmt((c * 100).rounded() / 100)
                return (c > 0 ? "+" : "") + v + "%"
            }.joined(separator: ", ")
            return ("Period-over-period change (\(changes.count) steps): \(list)", [])

        case "running_total":
            guard let data = arg("data"), !data.isEmpty else { return ("Missing 'data' (numbers).", []) }
            let nums = NumberStats.parse(data)
            guard !nums.isEmpty else { return ("Couldn't parse any numbers from the data.", []) }
            let totals = Fathom.Series.runningTotal(nums)
            let list = totals.map { Quartiles.fmt(($0 * 100).rounded() / 100) }.joined(separator: ", ")
            return ("Running totals (\(totals.count) values): \(list) — grand total \(Quartiles.fmt((totals.last! * 100).rounded() / 100)).", [])

        case "tally":
            guard let data = arg("data"), !data.isEmpty else { return ("Missing 'data' (a list of values).", []) }
            guard let summary = Tally.summary(data) else {
                return ("Couldn't find any values to tally. Pass values one per line or comma-separated.", [])
            }
            return (summary, [])

        default:
            return nil
        }
    }
}
