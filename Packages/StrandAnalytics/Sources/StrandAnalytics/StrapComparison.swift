import Foundation

/// Read-only comparison of the same metric from two straps. It never changes canonical ownership.
public enum StrapComparison {
    public struct Row: Equatable, Sendable {
        public let metric: MetricArbitrationPolicy.MetricKind
        public let a: Double?
        public let b: Double?
        public let agreement: AgreementState

        public init(
            metric: MetricArbitrationPolicy.MetricKind,
            a: Double?,
            b: Double?,
            agreement: AgreementState
        ) {
            self.metric = metric
            self.a = a
            self.b = b
            self.agreement = agreement
        }
    }

    public static func compare(
        _ a: [MetricArbitrationPolicy.MetricKind: Double],
        _ b: [MetricArbitrationPolicy.MetricKind: Double]
    ) -> [Row] {
        MetricArbitrationPolicy.MetricKind.allCases.compactMap { metric in
            guard metric != .other else { return nil }
            let first = validValue(a[metric], for: metric)
            let second = validValue(b[metric], for: metric)
            guard first != nil || second != nil else { return nil }
            return Row(metric: metric, a: first, b: second,
                       agreement: agreement(metric: metric, a: first, b: second))
        }
    }

    public static func agreement(
        metric: MetricArbitrationPolicy.MetricKind,
        a: Double?,
        b: Double?
    ) -> AgreementState {
        guard let a = validValue(a, for: metric),
              let b = validValue(b, for: metric) else { return .single }
        let tolerance = MetricArbitrationPolicy.tolerance(metric: metric)
        let delta = abs(a - b)
        let base = max(abs(a), abs(b))
        let agreeEdge = tolerance.isPercent ? tolerance.agree * base : tolerance.agree
        let minorEdge = tolerance.isPercent ? tolerance.minorDelta * base : tolerance.minorDelta
        if delta <= agreeEdge { return .agree }
        if delta <= minorEdge { return .minorDelta }
        return .conflict
    }

    private static func validValue(
        _ value: Double?,
        for metric: MetricArbitrationPolicy.MetricKind
    ) -> Double? {
        guard let value, value.isFinite else { return nil }
        let valid: Bool
        switch metric {
        case .restingHR, .heartRate: valid = (20...300).contains(value)
        case .hrv: valid = (0...1_000).contains(value)
        case .spo2: valid = (0...100).contains(value)
        case .skinTemp: valid = (-20...100).contains(value)
        case .steps: valid = (0...1_000_000).contains(value)
        case .sleep: valid = (0...1_440).contains(value)
        case .calories: valid = (0...100_000).contains(value)
        case .other: valid = false
        }
        return valid ? value : nil
    }
}
