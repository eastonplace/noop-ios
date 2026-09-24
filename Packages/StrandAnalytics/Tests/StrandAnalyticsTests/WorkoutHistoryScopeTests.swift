import XCTest
import WhoopStore
@testable import StrandAnalytics

final class WorkoutHistoryScopeTests: XCTestCase {
    func testBoundaryPartitionsWithoutDeletingOrDuplicatingRows() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cutoff = Int(calendar.date(byAdding: .day, value: -90, to: calendar.startOfDay(for: now))!.timeIntervalSince1970)
        let rows = [workout(cutoff - 1), workout(cutoff), workout(cutoff + 1)]
        let current = WorkoutHistoryScope.filter(rows, scope: .current, now: now, calendar: calendar)
        let archived = WorkoutHistoryScope.filter(rows, scope: .archived, now: now, calendar: calendar)
        XCTAssertEqual(current.map(\.startTs), [cutoff, cutoff + 1])
        XCTAssertEqual(archived.map(\.startTs), [cutoff - 1])
        XCTAssertEqual(current.count + archived.count, rows.count)
    }
    private func workout(_ ts: Int) -> WorkoutRow {
        WorkoutRow(startTs: ts, endTs: ts + 600, sport: "Running", source: "manual",
                   durationS: 600, energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
                   distanceM: nil, zonesJSON: nil, notes: nil)
    }
}
