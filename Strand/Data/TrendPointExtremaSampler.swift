import Foundation
import StrandDesign

/// Render-budgeted chronological sampling for compact trend sparklines.
///
/// Equal-index sampling can completely erase a short-lived spike or trough between chosen indices. This
/// projection keeps the first and last point plus each bucket's chronological minimum and maximum, preserving
/// the important shape while retaining a fixed upper bound for SwiftUI rendering.
enum TrendPointExtremaSampler {
    static func sample(_ points: [TrendPoint], maximumCount: Int) -> [TrendPoint] {
        guard maximumCount > 0 else { return [] }
        let ordered = points
            .filter { $0.value.isFinite && $0.date.timeIntervalSinceReferenceDate.isFinite }
            .sorted { $0.date < $1.date }
        guard maximumCount > 1 else { return ordered.last.map { [$0] } ?? [] }
        let limit = maximumCount
        guard ordered.count > limit else { return ordered }
        guard let first = ordered.first, let last = ordered.last else { return [] }

        let interior = Array(ordered.dropFirst().dropLast())
        let interiorBudget = limit - 2
        guard interiorBudget > 0, !interior.isEmpty else { return [first, last] }

        let bucketCount = max(1, interiorBudget / 2)
        let bucketSize = max(1, Int(ceil(Double(interior.count) / Double(bucketCount))))
        var result: [TrendPoint] = [first]
        result.reserveCapacity(limit)

        var start = 0
        while start < interior.count && result.count < limit - 1 {
            let end = min(interior.count, start + bucketSize)
            let bucket = interior[start..<end]
            guard let minimum = bucket.enumerated().min(by: { $0.element.value < $1.element.value }),
                  let maximum = bucket.enumerated().max(by: { $0.element.value < $1.element.value })
            else { break }

            let candidates: [TrendPoint]
            if minimum.offset == maximum.offset {
                candidates = [minimum.element]
            } else if minimum.offset < maximum.offset {
                candidates = [minimum.element, maximum.element]
            } else {
                candidates = [maximum.element, minimum.element]
            }
            for candidate in candidates where result.count < limit - 1 {
                result.append(candidate)
            }
            start = end
        }

        result.append(last)
        return result
    }
}
