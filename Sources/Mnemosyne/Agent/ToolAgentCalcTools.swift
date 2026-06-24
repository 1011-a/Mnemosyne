import Foundation
import Fathom

/// Calculator / unit-conversion / finance / validation tool handlers, extracted from `ToolAgent`'s
/// main `handleTool` switch to keep that file focused. Pure value-in/value-out (no store/network/
/// UI). `handleCalcTool` returns nil when `name` isn't one of these, letting the caller fall
/// through. Most map 1:1 to Fathom built-in tools; a few (`calculate`, `unit_convert`, the finance
/// helpers) have no Fathom equivalent and stay backed by app-local pure helpers.
extension ToolAgent {
    func handleCalcTool(_ name: String, args: String) -> (String, [Citation])? {
        func arg(_ k: String) -> String? { Self.stringArg(args, k) }
        switch name {
        case "number_bases":
            guard let value = arg("value"), !value.isEmpty else { return ("Missing 'value'.", []) }
            guard let described = Fathom.NumberBases.describe(value) else {
                return ("'\(value)' isn't a valid integer (try decimal or 0x/0b/0o-prefixed).", [])
            }
            return (described, [])

        case "convert_base":
            guard let value = arg("value"), !value.isEmpty,
                  let from = Int(arg("from") ?? ""), let to = Int(arg("to") ?? "") else {
                return ("Need 'value' and integer 'from'/'to' bases.", [])
            }
            guard let out = Fathom.BaseConvert.convert(value, from: from, to: to) else {
                return ("Couldn't convert — bases must be 2–36 and '\(value)' valid in base \(from).", [])
            }
            return ("\(value) (base \(from)) = \(out) (base \(to))", [])

        case "calculate":
            guard let expr = arg("expression")?.trimmingCharacters(in: .whitespacesAndNewlines), !expr.isEmpty
            else { return ("Missing 'expression'.", []) }
            guard let v = Calculator.eval(expr) else {
                return ("Couldn't evaluate '\(expr)' — check the expression (only + - * / % ^ and parentheses).", [])
            }
            return ("\(expr) = \(Calculator.format(v))", [])

        case "unit_convert":
            guard let vs = arg("value"), let v = Double(vs),
                  let from = arg("from"), let to = arg("to") else { return ("Missing 'value', 'from', or 'to'.", []) }
            guard let r = UnitConvert.convert(v, from: from, to: to) else {
                return ("Can't convert '\(from)' to '\(to)' — unknown units or different dimensions.", [])
            }
            return ("\(Calculator.format(v)) \(from) = \(Calculator.format(r)) \(to)", [])

        case "roman_numeral":
            guard let value = arg("value"), !value.isEmpty else { return ("Missing 'value'.", []) }
            guard let out = Fathom.RomanNumeral.convert(value) else {
                return ("Couldn't convert '\(value)' — use a number 1–3999 or a valid Roman numeral.", [])
            }
            return ("\(value) = \(out)", [])

        case "duration":
            guard let value = arg("value"), !value.isEmpty else { return ("Missing 'value'.", []) }
            if let secs = Int(value.trimmingCharacters(in: .whitespaces)) {
                return ("\(secs) seconds = \(Fathom.HumanDuration.humanize(secs))", [])
            }
            guard let secs = Fathom.HumanDuration.parse(value) else {
                return ("Couldn't parse '\(value)' — use seconds, '1h 30m', or '1:30:00'.", [])
            }
            return ("\(value) = \(secs) seconds (\(Fathom.HumanDuration.humanize(secs)))", [])

        case "file_size":
            guard let value = arg("value"), !value.isEmpty else { return ("Missing 'value'.", []) }
            if let bytes = Int(value.trimmingCharacters(in: .whitespaces)) {
                return ("\(bytes) bytes = \(Fathom.ByteSize.humanize(bytes))", [])
            }
            guard let bytes = Fathom.ByteSize.parse(value) else {
                return ("Couldn't parse '\(value)' — use bytes or a size like '1.5 MB'.", [])
            }
            return ("\(value) = \(bytes) bytes", [])

        case "number_to_words":
            guard let value = arg("value"), let n = Int(value.trimmingCharacters(in: .whitespaces)) else {
                return ("Need an integer 'value'.", [])
            }
            guard let words = Fathom.NumberWords.spell(n) else { return ("That number is too large to spell out.", []) }
            return ("\(n) = \(words)", [])

        case "number_format":
            guard let value = arg("value"), !value.isEmpty else { return ("Missing 'value'.", []) }
            guard let out = Fathom.NumberFormat.grouped(value) else { return ("'\(value)' isn't a number.", []) }
            return (out, [])

        case "ordinal":
            guard let value = arg("value"), let n = Int(value.trimmingCharacters(in: .whitespaces)) else {
                return ("Need an integer 'value'.", [])
            }
            return (Fathom.Ordinal.format(n), [])

        case "gcd_lcm":
            guard let a = Int(arg("a") ?? ""), let b = Int(arg("b") ?? "") else { return ("Need integer 'a' and 'b'.", []) }
            return ("gcd(\(a), \(b)) = \(Fathom.IntMath.gcd(a, b)), lcm = \(Fathom.IntMath.lcm(a, b))", [])

        case "factorize":
            guard let n = Int(arg("value") ?? "") else { return ("Need an integer 'value'.", []) }
            guard n >= 2, n <= 1_000_000_000_000 else { return ("Give an integer between 2 and 1,000,000,000,000.", []) }
            if Fathom.IntMath.isPrime(n) { return ("\(n) is prime.", []) }
            let factors = Fathom.IntMath.factorize(n)
            return ("\(n) = \(factors.map(String.init).joined(separator: " × "))", [])

        case "temperature":
            guard let value = Double(arg("value") ?? ""), let from = arg("from"), let to = arg("to") else {
                return ("Need numeric 'value' and 'from'/'to' units (C, F, or K).", [])
            }
            guard let result = Fathom.Temperature.convert(value, from: from, to: to) else {
                return ("Units must be C, F, or K.", [])
            }
            return ("\(Fathom.Temperature.fmt(value))° \(from.uppercased().prefix(1)) = \(Fathom.Temperature.fmt(result))° \(to.uppercased().prefix(1))", [])

        case "color":
            guard let value = arg("value"), !value.isEmpty else { return ("Missing 'value'.", []) }
            guard let out = Fathom.ColorConvert.describe(value) else {
                return ("Couldn't parse '\(value)' as a color — use #RRGGBB, #RGB, or 'r,g,b' (0–255).", [])
            }
            return (out, [])

        case "luhn":
            guard let value = arg("value"), !value.isEmpty else { return ("Missing 'value'.", []) }
            let valid = Fathom.Luhn.isValid(value)
            return ("\(value) is \(valid ? "valid" : "invalid") (Luhn checksum).", [])

        case "password_strength":
            guard let pw = arg("password"), !pw.isEmpty else { return ("Missing 'password'.", []) }
            guard let r = Fathom.PasswordStrength.evaluate(pw) else { return ("Nothing to evaluate.", []) }
            return ("\(Int(r.bits.rounded())) bits of entropy — \(r.label) (\(pw.count) chars, pool \(r.poolSize)).", [])

        case "validate_email":
            guard let email = arg("email"), !email.isEmpty else { return ("Missing 'email'.", []) }
            return ("'\(email)' is \(Fathom.Email.isValid(email) ? "a valid" : "not a valid") email address.", [])

        case "percentage":
            guard let mode = arg("mode"),
                  let a = Double(arg("a") ?? ""), let b = Double(arg("b") ?? "") else {
                return ("Need 'mode' and numeric 'a' and 'b'.", [])
            }
            switch mode.lowercased() {
            case "of":
                return ("\(Percentage.fmt(a))% of \(Percentage.fmt(b)) = \(Percentage.fmt(Percentage.of(a, b)))", [])
            case "what_percent":
                guard let p = Percentage.whatPercent(a, of: b) else { return ("Can't divide by zero (b is 0).", []) }
                return ("\(Percentage.fmt(a)) is \(Percentage.fmt(p))% of \(Percentage.fmt(b))", [])
            case "change":
                guard let c = Percentage.change(from: a, to: b) else { return ("Can't compute change from 0.", []) }
                let sign = c > 0 ? "+" : ""
                return ("From \(Percentage.fmt(a)) to \(Percentage.fmt(b)) is \(sign)\(Percentage.fmt(c))%", [])
            default:
                return ("Unknown mode. Use 'of', 'what_percent', or 'change'.", [])
            }

        case "tip":
            guard let bill = Double(arg("bill") ?? ""), let percent = Double(arg("percent") ?? "") else {
                return ("Need numeric 'bill' and 'percent'.", [])
            }
            let people = Swift.max(Int(arg("people") ?? "") ?? 1, 1)
            guard let r = TipCalculator.compute(bill: bill, percent: percent, people: people) else {
                return ("Bill and percent must be ≥ 0.", [])
            }
            let f: (Double) -> String = { String(format: "%.2f", $0) }
            let split = people > 1 ? " — \(f(r.perPerson)) each (\(people) people)" : ""
            return ("Tip \(f(r.tip)) (\(Percentage.fmt(percent))%), total \(f(r.total))\(split).", [])

        case "loan_payment":
            guard let principal = Double(arg("principal") ?? ""), let rate = Double(arg("rate") ?? ""),
                  let years = Double(arg("years") ?? "") else {
                return ("Need numeric 'principal', 'rate', and 'years'.", [])
            }
            guard let m = LoanPayment.monthlyPayment(principal: principal, annualRatePct: rate, years: years),
                  let interest = LoanPayment.totalInterest(principal: principal, annualRatePct: rate, years: years) else {
                return ("Principal must be ≥ 0 and years > 0.", [])
            }
            let f: (Double) -> String = { String(format: "%.2f", $0) }
            return ("\(f(principal)) at \(Percentage.fmt(rate))%/yr over \(Percentage.fmt(years)) years → \(f(m))/month. Total interest \(f(interest)), total paid \(f(principal + interest)).", [])

        case "compound_interest":
            guard let principal = Double(arg("principal") ?? ""), let rate = Double(arg("rate") ?? ""),
                  let years = Double(arg("years") ?? "") else {
                return ("Need numeric 'principal', 'rate', and 'years'.", [])
            }
            let m = Swift.max(Int(arg("times_per_year") ?? "") ?? 1, 1)
            guard let fv = CompoundInterest.futureValue(principal: principal, annualRatePct: rate, years: years, perYear: m) else {
                return ("Principal and years must be ≥ 0.", [])
            }
            let f: (Double) -> String = { String(format: "%.2f", $0) }
            let freq = m == 1 ? "annually" : (m == 12 ? "monthly" : (m == 4 ? "quarterly" : "\(m)×/year"))
            return ("\(f(principal)) at \(Percentage.fmt(rate))%/yr for \(Percentage.fmt(years)) years (\(freq)) → \(f(fv)) (interest \(f(fv - principal)))", [])

        default:
            return nil
        }
    }
}
