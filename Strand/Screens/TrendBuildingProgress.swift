import Foundation
import StrandDesign

// A trend's early state: with fewer than two days there is nothing to chart yet, so the section says how far along it
// is instead. Pure and tested.

struct TrendBuildingProgress: Equatable {
    /// The length of the strip the section shows: a week, the shortest range the trend offers.
    static let windowDays = 7
    /// The fewest days a trend needs before it is drawn.
    static let minimumDays = 2

    /// Which of the last `windowDays` days have a value, oldest first (the last is the reference day).
    let window: [Bool]

    var recordedDays: Int { window.filter { $0 }.count }

    /// - Parameters:
    ///   - values: the days that have a value.
    ///   - through: the last day of the strip.
    /// - Returns: nil once there are enough days for a chart.
    static func make(values: [CalendarMetricDay], through: Date, calendar: Calendar) -> TrendBuildingProgress? {
        guard values.filter({ $0.value != nil }).count < minimumDays else { return nil }
        let days = TrendCalendar.buildRollingWindow(
            observations: values, through: through, count: windowDays, calendar: calendar)
        return TrendBuildingProgress(window: days.map { $0.value != nil })
    }
}
