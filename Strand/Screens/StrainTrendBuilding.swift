import Foundation
import StrandDesign

// The Strain trend's early state. Pure and tested.

/// The trend's early state: with fewer than two days of strain there is nothing to chart yet, so the section says how
/// far along it is instead.
struct StrainTrendBuilding: Equatable {
    static let windowDays = 7

    let recordedDays: Int

    /// - Parameters:
    ///   - values: the days that have a strain value.
    ///   - through: the last day of the window.
    static func make(values: [CalendarMetricDay], through: Date, calendar: Calendar) -> StrainTrendBuilding? {
        let window = TrendCalendar.buildRollingWindow(
            observations: values, through: through, count: windowDays, calendar: calendar)
        let recorded = window.filter { $0.value != nil }.count
        let overall = values.filter { $0.value != nil }.count
        return overall < 2 ? StrainTrendBuilding(recordedDays: recorded) : nil
    }
}
