import Foundation

/// Primality test and prime factorization for the `factorize` tool. Trial division to √n —
/// fine for everyday values (the tool caps the input). Pure + deterministic → unit-testable.
enum PrimeUtil {
    static func isPrime(_ n: Int) -> Bool {
        if n < 2 { return false }
        if n < 4 { return true }          // 2, 3
        if n % 2 == 0 { return false }
        var i = 3
        while i * i <= n {
            if n % i == 0 { return false }
            i += 2
        }
        return true
    }

    /// Prime factors with multiplicity, ascending (e.g. 60 → [2, 2, 3, 5]). n < 2 → [].
    static func factorize(_ n: Int) -> [Int] {
        guard n > 1 else { return [] }
        var x = n
        var out: [Int] = []
        var d = 2
        while d * d <= x {
            while x % d == 0 { out.append(d); x /= d }
            d += (d == 2) ? 1 : 2
        }
        if x > 1 { out.append(x) }
        return out
    }
}
