import XCTest
@testable import StrandAnalytics

final class LoadFocusTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private let end = Date(timeIntervalSince1970: 1_800_000_000)

    private func workout(daysAgo: Double, _ minutes: [Double]?) -> LoadFocus.Workout {
        .init(start: end.addingTimeInterval(-daysAgo * 86_400), zoneMinutes: minutes)
    }

    func testSplitWeightsMinutesLikeStrain() throws {
        // 10 min Z1 (x1) + 10 min Z2 (x2) = 30 low; 10 min Z3 (x3) + 10 min Z4 (x4) = 70 high; 10 min Z5 (x5) = 50.
        let split = try XCTUnwrap(LoadFocus.split(zoneMinutes: [10, 10, 10, 10, 10]))
        XCTAssertEqual(split.load, [30, 70, 50])
        XCTAssertEqual(split.fraction(.anaerobic), 50.0 / 150.0, accuracy: 1e-9)
    }

    func testSplitRejectsEmptyAndMalformed() {
        XCTAssertNil(LoadFocus.split(zoneMinutes: [0, 0, 0, 0, 0]))
        XCTAssertNil(LoadFocus.split(zoneMinutes: [1, 2, 3]))
        XCTAssertNil(LoadFocus.split(zoneMinutes: [.nan, -3, 0, 0, 0]))
    }

    func testStatusInRangeBelowAbove() {
        XCTAssertEqual(LoadFocus.status(percent: 46, target: 35...55), .inRange)
        XCTAssertEqual(LoadFocus.status(percent: 35, target: 35...55), .inRange)
        XCTAssertEqual(LoadFocus.status(percent: 30, target: 35...55), .below(5))
        XCTAssertEqual(LoadFocus.status(percent: 16, target: 5...15), .above(1))
    }

    func testPercentsSumToHundred() {
        XCTAssertEqual(LoadFocus.wholePercents([1.0 / 3, 1.0 / 3, 1.0 / 3]).reduce(0, +), 100)
    }

    func testReadySummaryAndWeeks() throws {
        // All in the newest week except one old workout; the fourth workout has no heart rate and is ignored.
        let workouts = [
            workout(daysAgo: 1, [10, 10, 0, 0, 0]),
            workout(daysAgo: 2, [0, 0, 10, 10, 0]),
            workout(daysAgo: 3, [0, 0, 0, 0, 10]),
            workout(daysAgo: 20, [10, 0, 0, 0, 0]),
            workout(daysAgo: 4, nil),
            workout(daysAgo: 40, [0, 0, 0, 0, 99]),
        ]
        guard case .ready(let summary) = LoadFocus.evaluate(workouts: workouts, through: end, calendar: calendar) else {
            return XCTFail("expected ready")
        }
        XCTAssertEqual(summary.workoutCount, 4)
        // Low 30 + 10 = 40, high 70, anaerobic 50 of 160.
        XCTAssertEqual(summary.shares.map(\.percent), [25, 44, 31])
        XCTAssertEqual(summary.shares.map(\.percent).reduce(0, +), 100)
        XCTAssertEqual(summary.shares[2].status, .above(16))
        XCTAssertEqual(summary.shares[0].status, .below(10))
        XCTAssertEqual(summary.largestGap?.bucket, .anaerobic)
        XCTAssertEqual(summary.weeks.count, 4)
        XCTAssertEqual(summary.weeks.map { $0.split.total }, [0, 10, 0, 150])
    }

    func testInsufficientBelowThreeWorkoutsWithHeartRate() {
        let workouts = [workout(daysAgo: 1, [10, 0, 0, 0, 0]), workout(daysAgo: 2, [10, 0, 0, 0, 0]),
                        workout(daysAgo: 3, nil), workout(daysAgo: 35, [10, 0, 0, 0, 0])]
        XCTAssertEqual(LoadFocus.evaluate(workouts: workouts, through: end, calendar: calendar),
                       .insufficient(workoutsWithHR: 2))
    }

    func testDriverSnapshotDropsFormerSplitWhenHeartRateDisappears() {
        let start = end.addingTimeInterval(-3_600)
        var snapshot = LoadFocus.splitsByStart(workouts: [.init(start: start, zoneMinutes: [30, 0, 0, 0, 0])])
        XCTAssertNotNil(snapshot[start])
        snapshot = LoadFocus.splitsByStart(workouts: [.init(start: start, zoneMinutes: nil)])
        XCTAssertNil(snapshot[start])
        XCTAssertTrue(LoadFocus.splitsByStart(workouts: []).isEmpty)
    }

    func testEmptyInput() {
        XCTAssertEqual(LoadFocus.evaluate(workouts: [], through: end, calendar: calendar), .insufficient(workoutsWithHR: 0))
    }
}
