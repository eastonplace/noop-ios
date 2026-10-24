import XCTest
import WhoopStore
@testable import NOOP

final class TrendsReturnHandoffTests: XCTestCase {
    func testUnchangedTabReturnKeepsCompletedRangeAndItsRenderedSnapshotKey() {
        let completed = data(completed: true)
        let provisional = data(completed: false)
        let firstPaint = TrendsSnapshotHandoff.firstPaintData(
            loaded: completed, provisional: provisional, rangeDays: 30, weekOffset: 0)

        XCTAssertEqual(firstPaint, completed,
            "An unchanged return must not collapse the completed sections into the preparing state")
        XCTAssertEqual(firstPaint.loadIdentity, completed.loadIdentity,
            "The retained snapshot key must stay valid while the same range is revalidated")
    }

    func testChangedRevisionUsesNewPublishedData() {
        let provisional = data(completed: false, revision: 12)
        XCTAssertEqual(TrendsSnapshotHandoff.firstPaintData(
            loaded: data(completed: true), provisional: provisional,
            rangeDays: 30, weekOffset: 0), provisional)
    }

    func testChangedCalorieProfileUsesNewPublishedData() {
        let provisional = data(completed: false, bmrKcalPerDay: 1_800)
        XCTAssertEqual(TrendsSnapshotHandoff.firstPaintData(
            loaded: data(completed: true, bmrKcalPerDay: 1_600), provisional: provisional,
            rangeDays: 30, weekOffset: 0), provisional)
    }

    func testChangedRangeOrWeekCannotReuseCompletedRange() {
        let completed = data(completed: true)
        let provisional = data(completed: false)
        for selection in [(7, 0), (30, -1)] {
            XCTAssertEqual(TrendsSnapshotHandoff.firstPaintData(
                loaded: completed, provisional: provisional,
                rangeDays: selection.0, weekOffset: selection.1), provisional)
        }
    }

    func testChangedCivilContextCannotReuseCompletedRange() {
        let completed = data(completed: true)
        for provisional in [data(completed: false, anchorDay: "2026-10-25"),
                            data(completed: false, timeZone: "America/New_York")] {
            XCTAssertEqual(TrendsSnapshotHandoff.firstPaintData(
                loaded: completed, provisional: provisional, rangeDays: 30, weekOffset: 0), provisional)
        }
    }

    private func data(completed: Bool, revision: Int = 11, anchorDay: String = "2026-10-24",
                      timeZone: String = "UTC", bmrKcalPerDay: Double? = nil) -> TrendsLoadedData {
        TrendsLoadedData(
            loadIdentity: completed ? TrendsLoadIdentity(
                revision: 5, anchorDay: anchorDay, timeZoneIdentifier: timeZone,
                rangeDays: 30, weekOffset: 0) : nil,
            revision: revision, anchorDay: anchorDay, timeZoneIdentifier: timeZone,
            canonicalDays: [], sleepPerfByDay: [:], stressByDay: [:], appleDays: [],
            bmrKcalPerDay: bmrKcalPerDay)
    }
}
