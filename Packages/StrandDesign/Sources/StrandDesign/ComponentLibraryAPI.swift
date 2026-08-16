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

public extension HRLiveModuleCard {
    init(
        _publicAPI: Void = (),
        samples: [HRTrackPoint],
        restingHR: Double? = nil,
        surfaceStyle: ComponentSurfaceStyle = .flat,
        timeLabel: @escaping (TimeInterval) -> String,
        onOpen: @escaping () -> Void = {}
    ) {
        self.samples = samples
        self.restingHR = restingHR
        self.surfaceStyle = surfaceStyle
        self.timeLabel = timeLabel
        self.onOpen = onOpen
    }
}

public extension HRTimelineChart {
    init(
        _publicAPI: Void = (),
        points: [HRTrackPoint],
        day: ClosedRange<TimeInterval>,
        sleep: HRSleepBand? = nil,
        workouts: [HRWorkoutMark] = [],
        timeLabel: @escaping (TimeInterval) -> String,
        title: String = "Heart rate",
        tint: Color? = nil,
        unit: String = "bpm",
        valueFormat: @escaping (Double) -> String = { value in
            value.isFinite ? value.formatted(.number.precision(.fractionLength(0))) : "—"
        },
        showsZoneLegend: Bool = true,
        zoomDomain: Binding<ClosedRange<TimeInterval>?>? = nil,
        zoomBounds: ClosedRange<TimeInterval>? = nil,
        onSettledWindow: @escaping (ClosedRange<TimeInterval>?) -> Void = { _ in }
    ) {
        self.points = points
        self.day = day
        self.sleep = sleep
        self.workouts = workouts
        self.timeLabel = timeLabel
        self.title = title
        self.tint = tint
        self.unit = unit
        self.valueFormat = valueFormat
        self.showsZoneLegend = showsZoneLegend
        self.zoomDomainBinding = zoomDomain
        self.zoomBounds = zoomBounds
        self.onSettledWindow = onSettledWindow
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

public extension StressModuleCard {
    init(
        _publicAPI: Void = (),
        hours: [Double?],
        value: Double?,
        nowHour: Int = 17,
        surfaceStyle: ComponentSurfaceStyle = .flat,
        presentationMode: StressPresentationMode = .baselineCalibration,
        onOpen: @escaping () -> Void = {}
    ) {
        self.hours = hours
        self.value = value
        self.presentationMode = presentationMode
        self.nowHour = nowHour
        self.surfaceStyle = surfaceStyle
        self.onOpen = onOpen
    }
}

public extension RecoveryArcCard {
    init(_publicAPI: Void = (), score: Double?, yesterday: Double?, baseline: String, yesterdayLabel: String, sevenDay: String) {
        self.score = score
        self.yesterday = yesterday
        self.baseline = baseline
        self.yesterdayLabel = yesterdayLabel
        self.sevenDay = sevenDay
    }
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

public extension RecoveryHistoryStrip {
    init(_publicAPI: Void = (), days: [CalendarMetricDay], anchorDate: Date,
         calendar: Calendar = .autoupdatingCurrent) {
        self.days = days
        self.anchorDate = anchorDate
        self.calendar = calendar
    }
}

public extension StrainGaugeCard {
    init(_publicAPI: Void = (), strain: Double, target: ClosedRange<Double>, sevenDayAverage: Double) {
        self.strain = strain
        self.target = target
        self.sevenDayAverage = sevenDayAverage
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

public extension StrainBuildupChart {
    init(
        _publicAPI: Void = (),
        points: [StrainBuildupPoint],
        target: ClosedRange<Double>,
        earns: [StrainEarnMark] = [],
        timeLabel: @escaping (TimeInterval) -> String
    ) {
        self.points = points
        self.target = target
        self.earns = earns
        self.timeLabel = timeLabel
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

public extension StrainWeekStrip {
    init(_publicAPI: Void = (), days: [CalendarMetricDay], target: ClosedRange<Double>,
         anchorDate: Date, referenceDate: Date = Date(), calendar: Calendar = .autoupdatingCurrent) {
        self.days = days
        self.target = target
        self.anchorDate = anchorDate
        self.referenceDate = referenceDate
        self.calendar = calendar
    }
}

public extension TrendPanelChart {
    init(
        _publicAPI: Void = (),
        days: [CalendarMetricDay],
        dateDomain: ClosedRange<Date>,
        referenceDate: Date,
        calendar: Calendar = .autoupdatingCurrent,
        baseline: Double,
        typical: ClosedRange<Double>,
        tint: Color,
        unit: String,
        valueFormat: @escaping (Double) -> String = { value in
            value.isFinite ? value.formatted(.number.precision(.fractionLength(0))) : "—"
        },
        range: TrendRange,
        direction: TrendPanelChart.Direction = .contextual
    ) {
        self.days = days.sorted { $0.date < $1.date }
        self.dateDomain = dateDomain
        self.referenceDate = referenceDate
        self.calendar = calendar
        self.baseline = baseline
        self.typical = typical
        self.tint = tint
        self.unit = unit
        self.valueFormat = valueFormat
        self.range = range
        self.direction = direction
    }
}

public extension TrendMonthHeat {
    init(_publicAPI: Void = (), days: [TrendCalendarDay], tint: Color,
         referenceDate: Date = Date(), calendar: Calendar = .autoupdatingCurrent,
         valueFormat: @escaping (Double) -> String = { value in
             value.isFinite ? value.formatted(.number.precision(.fractionLength(0))) : "—"
         },
         colorScale: TrendHeatColorScale = .intensity) {
        self.days = days
        self.tint = tint
        self.referenceDate = referenceDate
        self.calendar = calendar
        self.valueFormat = valueFormat
        self.colorScale = colorScale
    }
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

public extension TrendWeekdayBars {
    init(_publicAPI: Void = (), values: [Double?], tint: Color,
         referenceDate: Date = Date(), calendar: Calendar = .autoupdatingCurrent,
         valueFormat: @escaping (Double) -> String = { value in
             value.isFinite ? value.formatted(.number.precision(.fractionLength(0))) : "—"
         }) {
        self.values = Array(values.prefix(7)) + Array(repeating: nil, count: max(0, 7 - values.count))
        self.tint = tint
        self.referenceDate = referenceDate
        self.calendar = calendar
        self.valueFormat = valueFormat
    }
}
