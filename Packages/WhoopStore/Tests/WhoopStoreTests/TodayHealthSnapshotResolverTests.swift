import XCTest
@testable import WhoopStore

final class TodayHealthSnapshotResolverTests: XCTestCase {
    private func daily(_ day: String = "2026-08-03", recovery: Double? = nil,
                       sleep: Double? = nil) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: sleep, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil,
                    recovery: recovery, strain: nil, exerciseCount: nil)
    }

    private func value(_ value: Double, source: String = "my-whoop-noop", observedAt: Int? = nil,
                       frontier: Int? = nil, strainVersion: Int? = nil) -> TodayHealthMetricValue {
        TodayHealthMetricValue(value: value, sourceId: source, observedAt: observedAt,
                                rawFrontierTs: frontier, algorithmVersion: "test-v1",
                                strainVersion: strainVersion)
    }

    private func snapshot(day: String = "2026-08-03", generatedAt: Int, recovery: Double? = nil,
                          strain: Double? = nil, sleepScore: Double? = nil, sleepDuration: Double? = nil,
                          recoveryFrontier: Int? = nil, strainFrontier: Int? = nil,
                          sleepFrontier: Int? = nil) -> TodayHealthSnapshot {
        TodayHealthSnapshot(
            scopeId: "dashboard:my-whoop", deviceId: "my-whoop", displayDay: day,
            logicalDay: day, localDay: day, generatedAt: generatedAt,
            rawFrontierTs: [recoveryFrontier, strainFrontier, sleepFrontier].compactMap { $0 }.max(),
            dailyMetric: daily(day, recovery: recovery, sleep: sleepDuration),
            recovery: recovery.map { value($0, observedAt: generatedAt, frontier: recoveryFrontier) },
            strain: strain.map { value($0, observedAt: generatedAt, frontier: strainFrontier,
                                       strainVersion: 2) },
            sleepScore: sleepScore.map { value($0, observedAt: generatedAt, frontier: sleepFrontier) },
            sleepDurationMinutes: sleepDuration.map { value($0, observedAt: generatedAt,
                                                             frontier: sleepFrontier) }
        )
    }

    func testBlankLiveRefreshCannotErasePersistedMetricValues() {
        let persisted = snapshot(generatedAt: 100, recovery: 78, strain: 64, sleepScore: 86,
                                 sleepDuration: 445, recoveryFrontier: 90, strainFrontier: 90,
                                 sleepFrontier: 90)
        let live = snapshot(generatedAt: 200)

        let resolved = TodayHealthSnapshotResolver.resolve(persisted: persisted, live: live)

        XCTAssertEqual(resolved?.recovery?.value, 78)
        XCTAssertEqual(resolved?.strain?.value, 64)
        XCTAssertEqual(resolved?.strain?.strainVersion, 2)
        XCTAssertEqual(resolved?.sleepScore?.value, 86)
        XCTAssertEqual(resolved?.sleepDurationMinutes?.value, 445)
        XCTAssertEqual(resolved?.dailyMetric.recovery, 78)
        XCTAssertEqual(resolved?.dailyMetric.totalSleepMin, 445)
    }

    func testFresherLiveMetricWinsIndependentlyPerMetric() {
        let persisted = snapshot(generatedAt: 100, recovery: 70, strain: 54, sleepScore: 76,
                                 sleepDuration: 420, recoveryFrontier: 100, strainFrontier: 100,
                                 sleepFrontier: 100)
        let live = snapshot(generatedAt: 200, recovery: 82, strain: 55, sleepScore: nil,
                            sleepDuration: nil, recoveryFrontier: 101, strainFrontier: 99)

        let resolved = TodayHealthSnapshotResolver.resolve(persisted: persisted, live: live)

        XCTAssertEqual(resolved?.recovery?.value, 82, "new raw frontier wins Recovery")
        XCTAssertEqual(resolved?.strain?.value, 54, "older raw frontier cannot roll Strain back")
        XCTAssertEqual(resolved?.sleepScore?.value, 76, "missing Sleep remains visible")
        XCTAssertEqual(resolved?.sleepDurationMinutes?.value, 420)
    }

    func testBlankNewDayKeepsTheVisiblePriorSnapshot() {
        let persisted = snapshot(day: "2026-08-03", generatedAt: 100, recovery: 74, strain: 60,
                                 sleepScore: 80, sleepDuration: 430)
        let live = snapshot(day: "2026-08-04", generatedAt: 200)

        let resolved = TodayHealthSnapshotResolver.resolve(persisted: persisted, live: live)

        XCTAssertEqual(resolved, persisted)
    }

    func testRealNewDayReplacesThePriorSnapshotAsOneCoherentDay() {
        let persisted = snapshot(day: "2026-08-03", generatedAt: 100, recovery: 74, strain: 60,
                                 sleepScore: 80, sleepDuration: 430)
        let live = snapshot(day: "2026-08-04", generatedAt: 200, recovery: 81, strain: 7,
                            sleepScore: 88, sleepDuration: 455)

        let resolved = TodayHealthSnapshotResolver.resolve(persisted: persisted, live: live)

        XCTAssertEqual(resolved, live)
    }
}
