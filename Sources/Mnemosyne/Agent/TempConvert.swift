import Foundation

/// Temperature conversion between Celsius, Fahrenheit, and Kelvin for the `temperature` tool.
/// Done via Celsius as the pivot so the offsets are correct (a generic scaling converter gets
/// these wrong). Pure + deterministic → unit-testable.
enum TempConvert {
    /// Convert `value` from one unit to another. Units are matched by first letter (c/f/k,
    /// case-insensitive). Nil if a unit is unrecognized.
    static func convert(_ value: Double, from: String, to: String) -> Double? {
        guard let c = toCelsius(value, from), let result = fromCelsius(c, to) else { return nil }
        return result
    }

    private static func unit(_ s: String) -> Character? {
        s.trimmingCharacters(in: .whitespaces).lowercased().first
    }

    private static func toCelsius(_ v: Double, _ u: String) -> Double? {
        switch unit(u) {
        case "c": return v
        case "f": return (v - 32) * 5 / 9
        case "k": return v - 273.15
        default: return nil
        }
    }

    private static func fromCelsius(_ c: Double, _ u: String) -> Double? {
        switch unit(u) {
        case "c": return c
        case "f": return c * 9 / 5 + 32
        case "k": return c + 273.15
        default: return nil
        }
    }

    static func fmt(_ v: Double) -> String {
        if v == v.rounded() { return String(Int(v)) }
        return String(format: "%g", v)
    }
}
