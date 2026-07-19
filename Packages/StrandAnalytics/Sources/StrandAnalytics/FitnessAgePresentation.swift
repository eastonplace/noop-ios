import Foundation

public struct FitnessAgeTrendSample: Equatable, Sendable {
    public let date: Date
    public let fitnessAge: Double

    public init(date: Date, fitnessAge: Double) {
        self.date = date
        self.fitnessAge = fitnessAge
    }
}

public enum FitnessAgePresentation {
    public static let minimumPaceSamples = 12
    public static let minimumPaceSpan: TimeInterval = 90 * 86_400

    /// Least-squares slope expressed as Fitness Age years per calendar year. Sparse or short histories
    /// stay nil so the UI says Calibrating instead of amplifying a couple of noisy weekly points.
    public static func paceOfAging(samples: [FitnessAgeTrendSample]) -> Double? {
        let ordered = samples
            .filter { $0.fitnessAge.isFinite }
            .sorted { $0.date < $1.date }
        guard ordered.count >= minimumPaceSamples,
              let first = ordered.first, let last = ordered.last,
              last.date.timeIntervalSince(first.date) >= minimumPaceSpan else { return nil }

        let year: TimeInterval = 365.2425 * 86_400
        let xs = ordered.map { $0.date.timeIntervalSince(first.date) / year }
        let ys = ordered.map(\.fitnessAge)
        let meanX = xs.reduce(0, +) / Double(xs.count)
        let meanY = ys.reduce(0, +) / Double(ys.count)
        let numerator = zip(xs, ys).reduce(0.0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) }
        let denominator = xs.reduce(0.0) { $0 + pow($1 - meanX, 2) }
        guard denominator > 0 else { return nil }
        let slope = numerator / denominator
        return slope.isFinite ? slope : nil
    }

    /// Fractional chronological age for a plotted date, backed by the profile's real date of birth.
    public static func chronologicalAge(on date: Date, dateOfBirth: Date) -> Double {
        max(0, date.timeIntervalSince(dateOfBirth) / (365.2425 * 86_400))
    }

    public static func dynamicRailRange(fitnessAge: Double?, chronologicalAge: Double) -> ClosedRange<Double> {
        let values = [fitnessAge, chronologicalAge].compactMap { $0 }
        let low = max(FitnessAgeEngine.minAge, (values.min() ?? chronologicalAge) - 8)
        let high = min(FitnessAgeEngine.maxAge, (values.max() ?? chronologicalAge) + 8)
        if high - low >= 16 { return low...high }
        let centre = (low + high) / 2
        return max(FitnessAgeEngine.minAge, centre - 8)...min(FitnessAgeEngine.maxAge, centre + 8)
    }
}
