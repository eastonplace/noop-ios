import SwiftUI
import StrandDesign

// MARK: - Shared parts of the Recovery / Strain / Stress detail screens
//
// The three drill-ins from Today speak the same language as Today, Trends and Coach: flat sections opened by an
// eyebrow, one hairline between them with even air on both sides, and a range chart that is the Trends hero chart
// (same scrub, same range control, same hero morph). This file holds what they share so the three cannot drift.

/// The one hairline between two flat sections on a drill-in: the same 1pt hairline Today and Trends draw, with
/// the same air (10pt of layout above, 12pt below puts about 12.5pt of visible gap each side).
struct DrillInSeparator: View {
    var body: some View {
        TodaySectionSeparator(above: 10, below: 12)
    }
}

// MARK: - Typical range

enum DrillInTrendStats {
    /// The mean of `values` and the band around it that the chart shades as "typical": one standard deviation,
    /// never narrower than 4% of the mean or half a unit (the floors the Trends tab uses), so a flat run of
    /// days still reads as a band rather than a hairline.
    static func baselineAndTypical(of values: [Double]) -> (baseline: Double, typical: ClosedRange<Double>)? {
        let finite = values.filter(\.isFinite)
        guard !finite.isEmpty else { return nil }
        let mean = finite.reduce(0, +) / Double(finite.count)
        guard mean.isFinite else { return nil }
        let spread: Double
        if finite.count > 1 {
            let variance = finite.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(finite.count)
            spread = max(variance.squareRoot(), abs(mean) * 0.04, 0.5)
        } else {
            spread = max(abs(mean) * 0.1, 1)
        }
        return (mean, (mean - spread)...(mean + spread))
    }
}

// MARK: - Ranges

/// The ranges a drill-in chart offers. W, M, 3M and 6M are the Trends tab's own windows; 1Y and ALL are offered
/// only by a section that asks for them (Stress), so Trends and the pillar screens keep exactly four.
enum DrillInRange: String, CaseIterable, Identifiable {
    case week = "W", month = "M", quarter = "3M", half = "6M", year = "1Y", all = "ALL"

    var id: String { rawValue }

    static let standard: [DrillInRange] = [.week, .month, .quarter, .half]
    static let extended: [DrillInRange] = DrillInRange.allCases

    /// A year or more spans two calendar years, so its dates carry the year.
    var showsYear: Bool { self == .year || self == .all }

    /// The window length in days ending at `reference`. ALL starts at the earliest day with a value (never a
    /// window shorter than a month, so a short history is not stretched across the whole chart).
    func days(earliest: Date?, through reference: Date, calendar: Calendar) -> Int {
        switch self {
        case .week: 7
        case .month: 30
        case .quarter: 90
        case .half: 180
        case .year: 365
        case .all:
            if let earliest {
                max((calendar.dateComponents([.day], from: calendar.startOfDay(for: earliest),
                                             to: calendar.startOfDay(for: reference)).day ?? 0) + 1, 30)
            } else {
                30
            }
        }
    }

    /// "Last 90 days", or "All time" for ALL.
    func title(days: Int) -> String {
        self == .all ? String(localized: "All time") : String(localized: "Last \(days) days")
    }
}

// MARK: - Range section

/// A metric over the last 7 / 30 / 90 / 180 days: eyebrow, "Last N days" with the range control beside it, the
/// Trends hero chart, then Low / Average / High. The chart is `TrendsHeroChart`, so holding and dragging reads a
/// day, the hero value and its pill morph into that day, and the page still scrolls under a moving finger.
struct DrillInTrendSection: View {
    let title: String
    let metric: ProductionTrendMetric
    /// Sparse daily values (a day without a value is simply absent); the window fills the gaps.
    let observations: [CalendarMetricDay]
    let referenceDate: Date
    /// The latest score, which tints a recovery chart by its band.
    let latest: Double?
    var valueBounds: ClosedRange<Double>? = nil
    var emptyMessage: String? = nil
    /// With fewer than two days of data, say how far along the trend is ("Building, 1 of 7 days") in place of the
    /// range control and an empty plot.
    var showsBuildingState = false
    /// The range control's segments. Defaults to W / M / 3M / 6M, like Trends.
    var ranges: [DrillInRange] = DrillInRange.standard

    @State private var range: DrillInRange = .month
    private let calendar = Calendar.current

    var body: some View {
        let tint = metric.domainTint(latest: latest)
        if showsBuildingState, emptyMessage == nil,
           let building = TrendBuildingProgress.make(values: observations, through: referenceDate, calendar: calendar) {
            VStack(alignment: .leading, spacing: WidgetMetrics.headerSpacing) {
                SectionEyebrow(title: title, systemImage: metric.symbol, tint: tint)
                buildingState(building, tint: tint)
            }
        } else {
            rangeSection(tint: tint)
        }
    }

    @ViewBuilder
    private func rangeSection(tint: DomainTint) -> some View {
        let earliest = observations.map(\.date).min()
        let rangeDays = range.days(earliest: earliest, through: referenceDate, calendar: calendar)
        let days = TrendCalendar.buildRollingWindow(
            observations: observations, through: referenceDate, count: rangeDays, calendar: calendar)
        let values = days.compactMap(\.value)
        VStack(alignment: .leading, spacing: WidgetMetrics.headerSpacing) {
            SectionEyebrow(title: title, systemImage: metric.symbol, tint: tint)
            TrendsControlRow(
                leading: { _ in
                    Text(range.title(days: rangeDays))
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(1)
                },
                trailing: { rangePicker(days: rangeDays, earliest: earliest) }
            )
            // One lone day is a dot, not a trend: say so instead of drawing an empty plot and a footer that repeats it.
            if values.count >= 2,
               let stats = DrillInTrendStats.baselineAndTypical(of: values),
               let domain = TrendCalendar.dateDomain(through: referenceDate, count: rangeDays, calendar: calendar) {
                TrendsHeroChart(
                    days: days,
                    dateDomain: domain,
                    referenceDate: referenceDate,
                    calendar: calendar,
                    baseline: stats.baseline,
                    typical: stats.typical,
                    tint: tint,
                    colorsLineByBand: metric == .recovery,
                    unit: metric.unit,
                    valueFormat: metric.format,
                    valueBounds: valueBounds ?? metric.valueBounds,
                    direction: metric.chartDirection,
                    metricName: metric.rawValue,
                    longRange: range.showsYear
                )
                .id("\(metric.rawValue)-\(range.rawValue)")
                StatFooter(items: [
                    (String(localized: "Low"), metric.formatWithUnit(values.min() ?? .nan)),
                    (String(localized: "Average"), metric.formatWithUnit(stats.baseline)),
                    (String(localized: "High"), metric.formatWithUnit(values.max() ?? .nan)),
                ])
            } else {
                Text(emptyMessage ?? String(localized: "Not enough days to chart a trend yet."))
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
            }
        }
    }

    /// Compact: a week of dots (filled where there is a day), how many of them, and why there is no chart yet.
    private func buildingState(_ progress: TrendBuildingProgress, tint: DomainTint) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(Array(progress.window.enumerated()), id: \.offset) { index, filled in
                    Circle()
                        .fill(filled ? tint.accent : Color.clear)
                        .overlay(Circle().stroke(filled ? tint.accent : StrandPalette.hairlineStrong, lineWidth: 1.5))
                        .frame(width: 10, height: 10)
                        // The newest day is ringed, like the last capsule of a band strip.
                        .padding(2)
                        .overlay {
                            if index == progress.window.count - 1 {
                                Circle().stroke(StrandPalette.textTertiary, lineWidth: 1)
                            }
                        }
                }
            }
            .accessibilityHidden(true)
            Text("Building · \(progress.recordedDays) of \(TrendBuildingProgress.windowDays) days")
                .font(StrandFont.subhead.weight(.semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Not enough days to chart a trend yet.")
                .font(StrandFont.micro)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// The canonical segmented pill, announced as one adjustable "Range" control so VoiceOver reads "30 days"
    /// instead of the bare "M" (the same treatment the Trends tab gives it).
    private func rangePicker(days: Int, earliest: Date?) -> some View {
        SegmentedPillControl(ranges, selection: $range) { $0.rawValue }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Range")
            .accessibilityValue(range == .all ? String(localized: "All time") : String(localized: "\(days) days"))
            .accessibilityAdjustableAction { direction in
                guard let index = ranges.firstIndex(of: range) else { return }
                switch direction {
                case .increment: range = ranges[min(index + 1, ranges.count - 1)]
                case .decrement: range = ranges[max(index - 1, 0)]
                default: break
                }
            }
            .accessibilityActions {
                ForEach(ranges) { option in
                    Button(option.title(days: option.days(earliest: earliest,
                                                          through: referenceDate, calendar: calendar))) { range = option }
                }
            }
    }
}

// MARK: - Number formatting

enum DrillInFormat {
    /// A signed whole or one-decimal change in the device's locale ("+12", "−2", "+0.4").
    static func signed(_ value: Double, fractionDigits: Int = 0) -> String {
        // A change that rounds to nothing reads "0" (or "0.0"), never "-0.0" or "+0".
        let scale = pow(10, Double(fractionDigits))
        let rounded = (value * scale).rounded() / scale
        return (rounded == 0 ? 0 : rounded)
            .formatted(.number.precision(.fractionLength(fractionDigits)).sign(strategy: .always(includingZero: false)))
    }

    static func number(_ value: Double, fractionDigits: Int = 0) -> String {
        value.formatted(.number.precision(.fractionLength(fractionDigits)))
    }

    /// The date a pushed screen's header row names ("Fri, Oct 9"), one format for every drill-in that says which
    /// day it shows. A format style, so it follows the device's current locale each time it runs.
    static func headerDate(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}
