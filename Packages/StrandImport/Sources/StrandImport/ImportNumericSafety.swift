import Foundation

/// Conversion at an external-data boundary must fail for an unrepresentable number, rather than
/// trap the process. Keep the caller's existing rounding policy for every representable value.
public enum ImportNumericSafety {
    public static func integer(
        _ value: Double?, rounding: FloatingPointRoundingRule = .towardZero
    ) -> Int? {
        guard let value else { return nil }
        return Int(exactly: value.rounded(rounding))
    }

    /// Keep valid fractional readings verbatim until their eventual display/storage conversion.
    static func integerValue(
        _ value: Double?, rounding: FloatingPointRoundingRule = .toNearestOrAwayFromZero
    ) -> Double? {
        integer(value, rounding: rounding) == nil ? nil : value
    }
}
