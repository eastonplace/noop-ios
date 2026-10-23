import Foundation

// MultipleComparisons.swift — keeps "more things checked" from meaning "more false finds".
//
// Insights test every factor against every outcome. At p < 0.05 each, twenty null tests would be
// expected to produce one hit by luck alone. Benjamini–Hochberg controls the false-discovery rate
// across the whole family instead: sort the p-values, scale each by m / rank, and take the running
// minimum from the largest down so adjusted values stay monotone. An adjusted value below alpha
// means the family-wide share of false finds is expected to stay under alpha.

public enum MultipleComparisons {

    /// Benjamini–Hochberg adjusted p-values (q-values), in the same order as `pValues`.
    /// Non-finite inputs are treated as 1. Every output is clamped to [0, 1].
    public static func benjaminiHochberg(_ pValues: [Double]) -> [Double] {
        let m = pValues.count
        guard m > 0 else { return [] }
        let clean = pValues.map { $0.isFinite ? Swift.min(Swift.max($0, 0), 1) : 1 }
        // Ascending by p; ties keep input order so the result is deterministic.
        let order = clean.indices.sorted { clean[$0] != clean[$1] ? clean[$0] < clean[$1] : $0 < $1 }
        var adjusted = [Double](repeating: 1, count: m)
        var running = 1.0
        for rank in stride(from: m, through: 1, by: -1) {
            let index = order[rank - 1]
            running = Swift.min(running, clean[index] * Double(m) / Double(rank))
            adjusted[index] = Swift.min(running, 1)
        }
        return adjusted
    }
}
