import Foundation

/// Converts a value between units of length, mass, or temperature for the
/// `unit_convert` tool. Pure + deterministic → unit-testable. Length/mass use
/// base-unit factors; temperature uses offset formulas. Unknown or cross-dimension
/// pairs return nil.
enum UnitConvert {
    /// Factor to the base unit (length base = metre, mass base = gram).
    static let length: [String: Double] = [
        "m": 1, "km": 1000, "cm": 0.01, "mm": 0.001, "um": 1e-6, "nm": 1e-9,
        "mi": 1609.344, "yd": 0.9144, "ft": 0.3048, "in": 0.0254,
    ]
    static let mass: [String: Double] = [
        "g": 1, "kg": 1000, "mg": 0.001, "t": 1_000_000, "lb": 453.59237, "oz": 28.349523125,
    ]
    static let temps: Set<String> = ["c", "f", "k"]

    /// Map many spellings/plurals to a canonical symbol, or nil if unrecognised.
    static func canonical(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let alias: [String: String] = [
            "meter": "m", "metre": "m", "meters": "m", "metres": "m",
            "kilometer": "km", "kilometre": "km", "kilometers": "km", "kilometres": "km", "kms": "km",
            "centimeter": "cm", "centimetre": "cm", "centimeters": "cm",
            "millimeter": "mm", "millimetre": "mm", "millimeters": "mm",
            "micrometer": "um", "nanometer": "nm",
            "mile": "mi", "miles": "mi", "yard": "yd", "yards": "yd",
            "foot": "ft", "feet": "ft", "inch": "in", "inches": "in",
            "gram": "g", "grams": "g", "gramme": "g", "kilogram": "kg", "kilograms": "kg", "kilo": "kg", "kgs": "kg",
            "milligram": "mg", "milligrams": "mg", "tonne": "t", "tonnes": "t", "ton": "t",
            "pound": "lb", "pounds": "lb", "lbs": "lb", "ounce": "oz", "ounces": "oz",
            "celsius": "c", "centigrade": "c", "fahrenheit": "f", "kelvin": "k",
        ]
        if let a = alias[s] { return a }
        // Bare symbols (already canonical) pass through; strip a stray plural 's'.
        if length[s] != nil || mass[s] != nil || temps.contains(s) { return s }
        if s.hasSuffix("s"), case let trimmed = String(s.dropLast()),
           length[trimmed] != nil || mass[trimmed] != nil { s = trimmed; return s }
        return nil
    }

    static func convert(_ value: Double, from rawFrom: String, to rawTo: String) -> Double? {
        guard let f = canonical(rawFrom), let t = canonical(rawTo) else { return nil }
        if let bf = length[f], let bt = length[t] { return value * bf / bt }
        if let bf = mass[f], let bt = mass[t] { return value * bf / bt }
        if temps.contains(f), temps.contains(t) { return convertTemp(value, from: f, to: t) }
        return nil   // unknown or cross-dimension (e.g. m → kg)
    }

    /// Temperature via celsius as the pivot.
    static func convertTemp(_ v: Double, from f: String, to t: String) -> Double {
        let c: Double
        switch f { case "f": c = (v - 32) * 5 / 9; case "k": c = v - 273.15; default: c = v }
        switch t { case "f": return c * 9 / 5 + 32; case "k": return c + 273.15; default: return c }
    }
}
