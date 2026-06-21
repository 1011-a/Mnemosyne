import Foundation

/// A small, safe arithmetic evaluator for the `calculate` tool — exact math the LLM
/// shouldn't do in its head. Supports + - * / % ^ (right-assoc), parentheses, and
/// unary +/-, with correct precedence via recursive descent. Pure → unit-testable.
/// No identifiers/functions, so there's nothing unsafe to evaluate.
enum Calculator {
    enum Tok: Equatable { case num(Double), op(Character), lp, rp }

    static func eval(_ expr: String) -> Double? {
        guard let toks = tokenize(expr) else { return nil }
        var parser = Parser(toks)
        guard let v = parser.parseExpr(), parser.atEnd, v.isFinite else { return nil }
        return v
    }

    /// "3" not "3.0"; otherwise the natural decimal.
    static func format(_ v: Double) -> String {
        if v.rounded() == v && abs(v) < 1e15 { return String(Int(v)) }
        return String(v)
    }

    static func tokenize(_ s: String) -> [Tok]? {
        var toks: [Tok] = []
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == " " || c == "\t" { i += 1; continue }
            if c.isNumber || c == "." {
                var num = ""
                while i < chars.count, chars[i].isNumber || chars[i] == "." { num.append(chars[i]); i += 1 }
                guard let d = Double(num) else { return nil }
                toks.append(.num(d)); continue
            }
            switch c {
            case "+", "-", "*", "/", "%", "^": toks.append(.op(c))
            case "(": toks.append(.lp)
            case ")": toks.append(.rp)
            default: return nil   // unknown character ⇒ not a valid expression
            }
            i += 1
        }
        return toks.isEmpty ? nil : toks
    }

    // expr := term (('+'|'-') term)*  ·  term := power (('*'|'/'|'%') power)*
    // power := unary ('^' power)?     ·  unary := ('+'|'-') unary | primary
    // primary := num | '(' expr ')'
    private struct Parser {
        let t: [Tok]; var i = 0
        init(_ t: [Tok]) { self.t = t }
        var atEnd: Bool { i >= t.count }
        func peek() -> Tok? { i < t.count ? t[i] : nil }

        mutating func parseExpr() -> Double? {
            guard var lhs = parseTerm() else { return nil }
            while case .op(let o)? = peek(), o == "+" || o == "-" {
                i += 1; guard let rhs = parseTerm() else { return nil }
                lhs = o == "+" ? lhs + rhs : lhs - rhs
            }
            return lhs
        }
        mutating func parseTerm() -> Double? {
            guard var lhs = parsePower() else { return nil }
            while case .op(let o)? = peek(), o == "*" || o == "/" || o == "%" {
                i += 1; guard let rhs = parsePower() else { return nil }
                if (o == "/" || o == "%") && rhs == 0 { return nil }   // no divide-by-zero
                lhs = o == "*" ? lhs * rhs : (o == "/" ? lhs / rhs : lhs.truncatingRemainder(dividingBy: rhs))
            }
            return lhs
        }
        mutating func parsePower() -> Double? {
            guard let base = parseUnary() else { return nil }
            if case .op("^")? = peek() {
                i += 1; guard let exp = parsePower() else { return nil }   // right-assoc
                return pow(base, exp)
            }
            return base
        }
        mutating func parseUnary() -> Double? {
            if case .op(let o)? = peek(), o == "+" || o == "-" {
                i += 1; guard let v = parseUnary() else { return nil }
                return o == "-" ? -v : v
            }
            return parsePrimary()
        }
        mutating func parsePrimary() -> Double? {
            switch peek() {
            case .num(let d): i += 1; return d
            case .lp:
                i += 1
                guard let v = parseExpr(), case .rp? = peek() else { return nil }
                i += 1; return v
            default: return nil
            }
        }
    }
}
