import Combine
import Foundation

/// One lightweight clock owner for Today's presentation day. Repository data can remain byte-identical across
/// local midnight and the 04:00 logical-day rollover, so waiting for an unrelated sync/import to bump
/// `refreshSeq` can leave Yesterday rendered indefinitely. This scheduler performs no store read: at each exact
/// boundary it emits one Repository invalidation, which makes Today recompute its existing keyed snapshot, then
/// re-arms for the next boundary. Scene activation recalculates the schedule after suspension or a timezone/
/// clock change. The Repository reference is weak and the task is cancelled while the app is inactive.
@MainActor
final class TodayDayBoundaryScheduler {
    static let shared = TodayDayBoundaryScheduler()

    private weak var repository: Repository?
    private var task: Task<Void, Never>?
    private(set) var active = false

    func setActive(
        _ active: Bool,
        repository: Repository,
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        self.active = active
        self.repository = repository
        task?.cancel()
        task = nil

        guard active else { return }
        arm(after: now, calendar: calendar)
    }

    /// The presentation key changes at local 00:00 (`localKey`) and local 04:00 (`logicalKey`). Return the
    /// first strictly-future boundary using Calendar arithmetic so DST days remain correct.
    nonisolated static func nextBoundary(after now: Date, calendar input: Calendar = .current) -> Date {
        let calendar = input
        let startOfToday = calendar.startOfDay(for: now)
        let nextMidnight = calendar.date(byAdding: .day, value: 1, to: startOfToday)
            ?? startOfToday.addingTimeInterval(86_400)
        let fourToday = calendar.date(
            bySettingHour: Repository.logicalDayRolloverHour,
            minute: 0,
            second: 0,
            of: startOfToday) ?? startOfToday.addingTimeInterval(
                Double(Repository.logicalDayRolloverHour) * 3_600)
        let nextFour = fourToday > now
            ? fourToday
            : (calendar.date(byAdding: .day, value: 1, to: fourToday)
                ?? fourToday.addingTimeInterval(86_400))
        return min(nextMidnight, nextFour)
    }

    private func arm(after now: Date, calendar: Calendar) {
        let boundary = Self.nextBoundary(after: now, calendar: calendar)
        let delay = max(0.05, boundary.timeIntervalSince(now))

        task = Task { @MainActor [weak self, weak repository] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self, self.active, let repository else { return }

            // One presentation invalidation only. `displayDayKey` includes both local/logical keys, so its
            // existing onChange rebuilds the snapshot with no database contention and no fabricated row.
            repository.objectWillChange.send()
            self.arm(after: boundary.addingTimeInterval(0.001), calendar: calendar)
        }
    }
}
