import SwiftUI
import StrandDesign
import WhoopStore

enum TodayWorkoutsProjection {
    static func rows(_ rows: [WorkoutRow], on day: Date, calendar: Calendar = .current) -> [WorkoutRow] {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        return rows.filter {
            let date = Date(timeIntervalSince1970: TimeInterval($0.startTs))
            return date >= start && date < end
        }.sorted { $0.startTs > $1.startTs }
    }
}

/// Kept for existing day-summary callers and tests. History presentation does not change its arithmetic.
struct TodayWorkoutsSummary: Equatable {
    let sessions: Int
    let activeSeconds: Double
    let energyKcal: Double

    init(sessions: Int, activeSeconds: Double, energyKcal: Double) {
        self.sessions = sessions
        self.activeSeconds = activeSeconds
        self.energyKcal = energyKcal
    }

    init(rows: [WorkoutRow]) {
        self.init(
            sessions: rows.count,
            activeSeconds: rows.reduce(0) { $0 + (WorkoutFacts.activeSeconds($1) ?? 0) },
            energyKcal: rows.reduce(0) { $0 + max(0, $1.energyKcal ?? 0) })
    }
}

/// The existing Rings/Today entry now opens the shared history-first hub.
/// The selected Today day intentionally does not narrow the feed to a single day.
/// `day` remains part of the route contract so existing callers do not need navigation rewrites.
struct TodayWorkoutsView: View {
    let day: Date
    var body: some View { WorkoutsView() }
}
