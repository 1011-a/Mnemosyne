import Foundation

/// Spells an integer in English words for the `number_to_words` tool — "1234" → "one thousand
/// two hundred thirty-four". Handles zero, negatives, and groups up to trillions. Pure +
/// deterministic → unit-testable.
enum NumberWords {
    private static let ones = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
        "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
        "seventeen", "eighteen", "nineteen",
    ]
    private static let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
    private static let scales = ["", "thousand", "million", "billion", "trillion"]

    static func spell(_ n: Int) -> String? {
        if n == 0 { return "zero" }
        var num = abs(n)
        var groups: [Int] = []
        while num > 0 { groups.append(num % 1000); num /= 1000 }
        guard groups.count <= scales.count else { return nil }   // beyond trillions

        var parts: [String] = []
        for i in stride(from: groups.count - 1, through: 0, by: -1) where groups[i] != 0 {
            var s = below1000(groups[i])
            if i > 0 { s += " " + scales[i] }
            parts.append(s)
        }
        let result = parts.joined(separator: " ")
        return n < 0 ? "negative " + result : result
    }

    private static func below1000(_ n: Int) -> String {
        var parts: [String] = []
        if n / 100 > 0 { parts.append(ones[n / 100] + " hundred") }
        let r = n % 100
        if r > 0 {
            if r < 20 {
                parts.append(ones[r])
            } else {
                let o = r % 10
                parts.append(o > 0 ? tens[r / 10] + "-" + ones[o] : tens[r / 10])
            }
        }
        return parts.joined(separator: " ")
    }
}
