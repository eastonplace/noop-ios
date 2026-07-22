import Foundation
import WhoopStore

/// One coherent, atomically-published input snapshot for Trends. Auxiliary metric reads can suspend at
/// different times; keeping them in separate `@State` properties briefly rendered Sleep from one refresh,
/// Stress from another, and Apple fallbacks from a third. The view now swaps this value only after all reads
/// for one repository revision complete.
struct TrendsLoadedData {
    let canonicalDays: [DailyMetric]
    let sleepPerfByDay: [String: Double]
    let stressByDay: [String: Double]
    let appleDays: [AppleDaily]
    let appleByDay: [String: AppleDaily]

    static let empty = TrendsLoadedData(
        canonicalDays: [],
        sleepPerfByDay: [:],
        stressByDay: [:],
        appleDays: []
    )

    init(
        canonicalDays: [DailyMetric],
        sleepPerfByDay: [String: Double],
        stressByDay: [String: Double],
        appleDays: [AppleDaily]
    ) {
        self.canonicalDays = canonicalDays
        self.sleepPerfByDay = sleepPerfByDay
        self.stressByDay = stressByDay
        self.appleDays = appleDays
        appleByDay = Dictionary(
            appleDays.map { ($0.day, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
    }
}
