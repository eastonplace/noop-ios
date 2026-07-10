import SwiftUI

/// Honest, user-facing state words for Recovery factors and Strain contributors.
///
/// The analytics package stays the source of truth for baselines and deviations. This
/// presentation helper only maps those engine outputs to the compact words/colors used
/// by Paper rows; a missing engine input always returns `nil` so the row stays value-only.
public enum FactorBand: String, Equatable, Sendable {
    case good
    case steady
    case fair
    case low
    case light
    case moderate
    case high

    /// Key resolved by the host app's catalog; all seven words already carry the
    /// shipped German/Italian translations there.
    public var localizationKey: String {
        switch self {
        case .good: return "Good"
        case .steady: return "Steady"
        case .fair: return "Fair"
        case .low: return "Low"
        case .light: return "Light"
        case .moderate: return "Moderate"
        case .high: return "High"
        }
    }

    public var color: Color {
        switch self {
        case .good: return StrandPalette.recoveryHigh
        case .steady, .light: return StrandPalette.textSecondary
        case .fair: return StrandPalette.warning
        case .moderate: return StrandPalette.effortAccent
        case .low, .high: return StrandPalette.recoveryLow
        }
    }
}

public enum FactorBands {
    /// D16's personal-baseline tolerance. Ratios and z-scores must come from
    /// `Baselines.deviation(_:state:)` in StrandAnalytics/Baselines.swift.
    public static let steadyRatio: Double = 0.05

    /// Higher HRV is better. A worse reading inside the engine's normal z-window is
    /// amber; a worse reading beyond it is red.
    public static func hrv(deviationRatio ratio: Double?, zScore: Double?) -> FactorBand? {
        guard let ratio, ratio.isFinite, let zScore, zScore.isFinite else { return nil }
        if ratio > steadyRatio { return .good }
        if ratio >= -steadyRatio { return .steady }
        // RecoveryScorer.logisticK documents ±2 z as the full red-green span.
        return zScore < -2 ? .low : .fair
    }

    /// Lower resting HR is better; this is the exact inverse of the HRV mapping.
    /// Ratio/z inputs cite `Baselines.deviation(_:state:)` in StrandAnalytics/Baselines.swift.
    public static func restingHR(deviationRatio ratio: Double?, zScore: Double?) -> FactorBand? {
        guard let ratio, ratio.isFinite, let zScore, zScore.isFinite else { return nil }
        if ratio < -steadyRatio { return .good }
        if ratio <= steadyRatio { return .steady }
        // RecoveryScorer.logisticK documents ±2 z as the full red-green span.
        return zScore > 2 ? .high : .fair
    }

    /// The 85% good-night boundary is `RecoveryScorer.sleepPerfCenter` in
    /// StrandAnalytics/RecoveryScorer.swift. D16 supplies the 70% Fair boundary.
    public static func sleepPerformance(percent: Double?) -> FactorBand? {
        guard let percent, percent.isFinite else { return nil }
        if percent >= 85 { return .good }
        if percent >= 70 { return .fair }
        return .low
    }

    /// The engine defines normal as |z| <= 1 in `Baselines.deviation(_:state:)`.
    public static func respiratoryRate(zScore: Double?) -> FactorBand? {
        guard let zScore, zScore.isFinite else { return nil }
        if abs(zScore) <= 1 { return .good }
        if abs(zScore) < 2 { return .fair }
        return zScore > 0 ? .high : .low
    }

    /// `typicalBandC` must be supplied from `RecoveryScorer.skinTempTypicalBandC`
    /// (StrandAnalytics/ChargeDrivers.swift), keeping the display tied to the engine.
    public static func skinTemperature(deviationC: Double?, typicalBandC: Double) -> FactorBand? {
        guard let deviationC, deviationC.isFinite, typicalBandC > 0 else { return nil }
        if abs(deviationC) <= typicalBandC { return .good }
        // RecoveryScorer.skinTempScaleC defines 1 °C as one full penalty z-unit.
        if abs(deviationC) < 1 { return .fair }
        return deviationC > 0 ? .high : .low
    }

    /// D16 defines >=85% max as High. Moderate begins at the real Zone 3 edge
    /// (`HRZones.zoneEdges == [..., 0.70, ...]` in StrandAnalytics/HRZones.swift).
    public static func heartRate(bpm: Double?, maxHR: Double?) -> FactorBand? {
        guard let bpm, bpm > 0, bpm.isFinite,
              let maxHR, maxHR > 0, maxHR.isFinite else { return nil }
        let fraction = bpm / maxHR
        if fraction >= 0.85 { return .high }
        if fraction >= 0.70 { return .moderate }
        return .light
    }
}
