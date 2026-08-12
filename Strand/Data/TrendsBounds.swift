import Foundation

/// Bounds all persisted, deep-linked, navigated, and loader-provided Trends state before arithmetic.
enum TrendsBounds {
    static let minimumWeekOffset = -520
    static let maximumWeekOffset = 0
    static let minimumRangeDays = 7
    static let maximumRangeDays = 365
    static let maximumRequiredDays = 3_710

    static func clampWeekOffset(_ value: Int) -> Int {
        min(maximumWeekOffset, max(minimumWeekOffset, value))
    }

    static func clampRangeDays(_ value: Int) -> Int {
        min(maximumRangeDays, max(minimumRangeDays, value))
    }

    static func requiredDays(rangeDays rawRangeDays: Int, weekOffset rawWeekOffset: Int) -> Int {
        let rangeDays = clampRangeDays(rawRangeDays)
        let weekOffset = clampWeekOffset(rawWeekOffset)
        let priorWeeks = -weekOffset
        let (doubleRange, rangeOverflow) = rangeDays.multipliedReportingOverflow(by: 2)
        let baselineWeeks = 8 + priorWeeks + 2
        let (baselineDays, baselineOverflow) = baselineWeeks.multipliedReportingOverflow(by: 7)
        guard !rangeOverflow, !baselineOverflow else { return maximumRequiredDays }
        return min(maximumRequiredDays, max(42, max(doubleRange, baselineDays)))
    }
}
