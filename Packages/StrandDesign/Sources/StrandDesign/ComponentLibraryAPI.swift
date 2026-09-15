import Foundation
import SwiftUI

/// Fail-closed presentation helpers for component defaults. Components are public building blocks, so
/// their own defaults must be safe even when a preview or a future caller bypasses app-level sanitation.
public enum ComponentValueFormat {
    public static func rounded(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        return value.formatted(.number.precision(.fractionLength(0)))
    }

    public static func oneDecimal(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        return value.formatted(.number.precision(.fractionLength(1)))
    }

    public static func percentage(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        return "\(rounded(value))%"
    }
}

/// Outer-container treatment for production components. Flat is the iOS app default;
/// card remains available for bounded previews and excluded surfaces.
public enum ComponentSurfaceStyle: Sendable {
    case flat
    case card
}

public extension HRTrackPoint {
    init(_publicAPI: Void = (), id: Int, t: TimeInterval, bpm: Double) {
        self.id = id
        self.t = t
        self.bpm = bpm
    }
}

public extension HRSleepBand {
    init(_publicAPI: Void = (), start: TimeInterval, end: TimeInterval, label: String) {
        self.start = start
        self.end = end
        self.label = label
    }
}

public extension HRWorkoutMark {
    init(_publicAPI: Void = (), id: Int, start: TimeInterval, end: TimeInterval, symbol: String) {
        self.id = id
        self.start = start
        self.end = end
        self.symbol = symbol
    }
}



public extension HRRangeStrip {
    init(_publicAPI: Void = (), low: String, lowDetail: String, average: String, averageDetail: String, peak: String, peakDetail: String) {
        self.low = low
        self.lowDetail = lowDetail
        self.average = average
        self.averageDetail = averageDetail
        self.peak = peak
        self.peakDetail = peakDetail
    }
}

public extension HRZoneTotal {
    init(_publicAPI: Void = (), id: String, label: String, duration: String, fraction: Double, zone: Int) {
        self.id = id
        self.label = label
        self.duration = duration
        self.fraction = fraction
        self.zone = zone
    }
}

public extension HRZoneTotalsView {
    init(_publicAPI: Void = (), totals: [HRZoneTotal]) { self.totals = totals }
}

public extension HRZoneLegend {
    init(_publicAPI: Void = ()) {}
}


public extension RecoveryStandingRow {
    init(_publicAPI: Void = (), percentile: Double, highDays: Int, mediumDays: Int, lowDays: Int) {
        self.percentile = percentile
        self.highDays = highDays
        self.mediumDays = mediumDays
        self.lowDays = lowDays
    }
}

public extension RecoveryDriverWeight {
    init(_publicAPI: Void = (), id: String, label: String, weight: Double, color: Color) {
        self.id = id
        self.label = label
        self.weight = weight
        self.color = color
    }
}

public extension RecoveryDriverSplit {
    init(_publicAPI: Void = (), weights: [RecoveryDriverWeight]) { self.weights = weights }
}

public extension RecoveryFactorRow {
    init(
        _publicAPI: Void = (),
        label: String,
        value: String,
        delta: String,
        tone: RecoveryFactorTone,
        position: Double,
        typical: ClosedRange<Double>,
        typicalLabel: String,
        nights: [Double],
        accent: Color
    ) {
        self.label = label
        self.value = value
        self.delta = delta
        self.tone = tone
        self.position = position
        self.typical = typical
        self.typicalLabel = typicalLabel
        self.nights = nights
        self.accent = accent
    }
}



public extension StrainBuildupPoint {
    init(_publicAPI: Void = (), id: Int, t: TimeInterval, strain: Double) {
        self.id = id
        self.t = t
        self.strain = strain
    }
}

public extension StrainEarnMark {
    init(_publicAPI: Void = (), id: Int, start: TimeInterval, end: TimeInterval, symbol: String, earned: Double) {
        self.id = id
        self.start = start
        self.end = end
        self.symbol = symbol
        self.earned = earned
    }
}


public extension StrainSummaryStrip {
    init(_publicAPI: Void = (), total: Double, active: Double, passive: Double) {
        self.total = total
        self.active = active
        self.passive = passive
    }
}

public extension StrainActivityRow {
    init(_publicAPI: Void = (), symbol: String, title: String, subtitle: String, context: String, strain: Double, share: Double) {
        self.symbol = symbol
        self.title = title
        self.subtitle = subtitle
        self.context = context
        self.strain = strain
        self.share = share
    }
}

public extension StrainZoneSlice {
    init(_publicAPI: Void = (), id: Int, name: String, range: String, minutes: Double) {
        self.id = id
        self.name = name
        self.range = range
        self.minutes = minutes
    }
}

public extension StrainZoneBar {
    init(_publicAPI: Void = (), slices: [StrainZoneSlice]) { self.slices = slices }
}



public extension TrendDeltaRow {
    init(_publicAPI: Void = (), label: String, subtitle: String, values: [Double], latest: String, delta: String, positive: Bool, tint: Color) {
        self.label = label
        self.subtitle = subtitle
        self.values = values
        self.latest = latest
        self.delta = delta
        self.tone = positive ? .positive : .negative
        self.tint = tint
    }

    init(_publicAPI: Void = (), label: String, subtitle: String, values: [Double], latest: String, delta: String, tone: TrendDeltaTone, tint: Color) {
        self.label = label
        self.subtitle = subtitle
        self.values = values
        self.latest = latest
        self.delta = delta
        self.tone = tone
        self.tint = tint
    }
}
