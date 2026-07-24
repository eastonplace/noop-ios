import Foundation
import WhoopStore

/// One coherent, atomically-published input snapshot for Trends. Auxiliary metric reads can suspend at
/// different times; keeping them in separate `@State` properties briefly rendered Sleep from one refresh,
/// Stress from another, and Apple fallbacks from a third. The view now swaps this value only after all reads
/// for one repository revision complete.
struct TrendsLoadedData: Equatable, Sendable {
    let revision: Int
    let anchorDay: String
    let timeZoneIdentifier: String
    let canonicalDays: [DailyMetric]
    let canonicalByDay: [String: DailyMetric]
    let sleepPerfByDay: [String: Double]
    let stressByDay: [String: Double]
    let appleDays: [AppleDaily]
    let appleByDay: [String: AppleDaily]

    static let empty = TrendsLoadedData(
        revision: -1,
        anchorDay: "",
        timeZoneIdentifier: "",
        canonicalDays: [],
        sleepPerfByDay: [:],
        stressByDay: [:],
        appleDays: []
    )

    init(
        revision: Int,
        anchorDay: String,
        timeZoneIdentifier: String,
        canonicalDays: [DailyMetric],
        sleepPerfByDay: [String: Double],
        stressByDay: [String: Double],
        appleDays: [AppleDaily]
    ) {
        self.revision = revision
        self.anchorDay = anchorDay
        self.timeZoneIdentifier = timeZoneIdentifier
        self.canonicalDays = canonicalDays.sorted { $0.day < $1.day }
        canonicalByDay = Dictionary(
            self.canonicalDays.map { ($0.day, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        self.sleepPerfByDay = sleepPerfByDay.filter { $0.value.isFinite }
        self.stressByDay = stressByDay.filter { $0.value.isFinite }
        self.appleDays = appleDays
        appleByDay = Dictionary(
            appleDays.map { ($0.day, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
    }
}
