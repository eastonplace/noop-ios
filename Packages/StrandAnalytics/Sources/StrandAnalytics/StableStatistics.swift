import Foundation

/// Numerically defensive helpers for analytics fed by imported local data. Every
/// result is finite or nil: callers never need to turn an overflow into UI text.
public enum StableStatistics {
    public static func mean(_ values: [Double]) -> Double? {
        let values = values.filter(\.isFinite)
        guard !values.isEmpty else { return nil }
        let scale = values.reduce(0.0) { max($0, abs($1)) }
        guard scale.isFinite else { return nil }
        guard scale > 0 else { return 0 }
        var running = 0.0
        for (index, value) in values.enumerated() {
            running += (value / scale - running) / Double(index + 1)
        }
        return scaledFinite(running, by: scale)
    }

    public static func sampleStandardDeviation(_ values: [Double], mean: Double) -> Double? {
        let values = values.filter(\.isFinite)
        guard values.count >= 2, mean.isFinite else { return values.count < 2 ? 0 : nil }
        let scale = values.reduce(0.0) { max($0, abs($1)) }
        guard scale.isFinite, scale > 0 else { return 0 }
        let centre = mean / scale
        guard centre.isFinite else { return nil }
        var sumSquares = 0.0
        for value in values {
            let delta = value / scale - centre
            sumSquares += delta * delta
        }
        let normalized = (sumSquares / Double(values.count - 1)).squareRoot()
        return scaledFinite(normalized, by: scale)
    }

    public static func leastSquaresSlope(_ values: [Double]) -> Double? {
        let values = values.filter(\.isFinite)
        guard values.count >= 2 else { return 0 }
        let scale = values.reduce(0.0) { max($0, abs($1)) }
        guard scale.isFinite, scale > 0 else { return 0 }
        let n = values.count
        let meanX = Double(n - 1) / 2
        guard let meanY = mean(values.map { $0 / scale }) else { return nil }
        var numerator = 0.0
        var denominator = 0.0
        for (index, value) in values.enumerated() {
            let dx = Double(index) - meanX
            numerator += dx * (value / scale - meanY)
            denominator += dx * dx
        }
        guard denominator > 0 else { return 0 }
        return scaledFinite(numerator / denominator, by: scale)
    }

    public static func difference(_ lhs: Double, _ rhs: Double) -> Double? {
        guard lhs.isFinite, rhs.isFinite else { return nil }
        let scale = max(abs(lhs), abs(rhs), 1)
        return scaledFinite(lhs / scale - rhs / scale, by: scale)
    }

    public static func percentChange(current: Double, previous: Double) -> Double? {
        guard previous.isFinite, current.isFinite, previous != 0 else { return nil }
        // Compute the ratio before rescaling. A saturated absolute difference would understate
        // opposite-sign extremes (for example +max vs -max is +200%, not +100%).
        let scale = max(abs(current), abs(previous), 1)
        let normalizedPrevious = previous / scale
        guard normalizedPrevious != 0 else { return nil }
        let result = ((current / scale - normalizedPrevious) / abs(normalizedPrevious)) * 100
        return result.isFinite ? result : nil
    }

    public static func roundedInt(_ value: Double) -> Int? {
        guard value.isFinite else { return nil }
        // `Double(Int.max)` rounds to 2^63 on 64-bit platforms, which is one past Int.max.
        // Bounds comparisons therefore still admit a value that traps in `Int(...)`. Exact
        // conversion after rounding is the only reliable representability check.
        return Int(exactly: value.rounded())
    }

    public static func rounded1(_ value: Double) -> Double? {
        guard value.isFinite, abs(value) <= Double.greatestFiniteMagnitude / 10 else { return nil }
        let result = (value * 10).rounded() / 10
        return result.isFinite ? result : nil
    }

    /// Rescale a finite normalized result without turning a mathematically valid extreme
    /// into infinity. Values beyond Double's representable range saturate with their sign;
    /// downstream ranking and direction remain honest instead of silently becoming zero.
    private static func scaledFinite(_ normalized: Double, by scale: Double) -> Double? {
        guard normalized.isFinite, scale.isFinite, scale >= 0 else { return nil }
        guard normalized != 0, scale != 0 else { return 0 }
        let result = normalized * scale
        if result.isFinite { return result }
        return normalized.sign == .minus ? -.greatestFiniteMagnitude : .greatestFiniteMagnitude
    }
}
