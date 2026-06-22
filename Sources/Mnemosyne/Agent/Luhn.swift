import Foundation

/// Luhn checksum validation for the `luhn` tool — the check digit scheme used by credit-card
/// numbers, IMEIs, and many IDs. Non-digits (spaces, dashes) are ignored. Pure +
/// deterministic → unit-testable.
enum Luhn {
    static func isValid(_ number: String) -> Bool {
        let digits = number.filter(\.isNumber).compactMap(\.wholeNumberValue)
        guard digits.count >= 2 else { return false }
        var sum = 0
        for (i, d) in digits.reversed().enumerated() {
            if i % 2 == 1 {
                let doubled = d * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += d
            }
        }
        return sum % 10 == 0
    }
}
