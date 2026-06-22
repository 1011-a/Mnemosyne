import Foundation

/// Simple moving average (rolling mean) over a fixed window for the `moving_average` tool —
/// smooths a number series to reveal its trend. Pure + deterministic → unit-testable.
/// Pairs with `NumberStats.parse` and `Sparkline`.
enum MovingAverage {
    /// Returns one average per window position, so the output has `count − window + 1` values.
    /// Needs window in 1…count, else nil.
    static func simple(_ nums: [Double], window: Int) -> [Double]? {
        guard window >= 1, window <= nums.count else { return nil }
        var out: [Double] = []
        out.reserveCapacity(nums.count - window + 1)
        var sum = nums.prefix(window).reduce(0, +)
        out.append(sum / Double(window))
        for i in window..<nums.count {
            sum += nums[i] - nums[i - window]   // slide the window
            out.append(sum / Double(window))
        }
        return out
    }
}
