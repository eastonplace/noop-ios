import XCTest
@testable import WhoopStore

final class TodayHealthSnapshotResolverTests: XCTestCase {
    private let context = TodayHealthSnapshotContext(
        databaseInstanceId: "test-db",
        dashboardProfileId: "dashboard:my-whoop",
        sourceLineage: "my-whoop,my-whoop-noop",
        algorithmBundleVersion: "today-health-v3|strain-v2|sleep-performance-v2"
    )

    private func daily(_ day: String, recovery: Double? = nil, strain: Double? = nil,
                       sleep: Double? = nil) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: sleep, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil,
                    recovery: recovery, strain: strain, exerciseCount: nil,
                    strainVersion: strain.map { _ in 2 })
    }

    private func snapshot(
        day: String = "2026-08-03",
        generatedAt: Int,
        recovery: Double? = nil,
        strain: Double? = nil,
        sleepScore: Double? = nil,
        sleepDuration: Double? = nil,
        recoveryFrontier: Int? = nil,
        strainFrontier: Int? = nil,
        sleepFrontier: Int? = nil,
        authoritativeMetrics: Set<TodayHealthSnapshot.Metric> = [],
        context: TodayHealthSnapshotContext? = nil
    ) -> TodayHealthSnapshot {
        let snapshotContext = context ?? self.context
        return TodayHealthSnapshot(
            scopeId: "dashboard:my-whoop|\(snapshotContext.identifier)", context: snapshotContext,
            deviceId: "my-whoop", displayDay: day, logicalDay: day, localDay: day,
            generatedAt: generatedAt,
            rawFrontierTs: [recoveryFrontier, strainFrontier, sleepFrontier].compactMap { $0 }.max(),
            authoritativeMetrics: authoritativeMetrics,
            dailyMetric: daily(day, recovery: recovery, strain: strain, sleep: sleepDuration),
            recovery: recovery.map {
                TodayHealthMetricValue(value: $0, metricDay: day, sourceId: "my-whoop-noop",
                                        observedAt: generatedAt, rawFrontierTs: recoveryFrontier,
                                        algorithmVersion: "daily-recovery-v1")
            },
            strain: strain.map {
                TodayHealthMetricValue(value: $0, metricDay: day, sourceId: "my-whoop-noop",
                                        observedAt: generatedAt, rawFrontierTs: strainFrontier,
                                        algorithmVersion: "strain-v2-daily", strainVersion: 2)
            },
            sleepScore: sleepScore.map {
                TodayHealthMetricValue(value: $0, metricDay: day, sourceId: "my-whoop-noop",
                                        observedAt: generatedAt, rawFrontierTs: sleepFrontier,
                                        algorithmVersion: "sleep-performance-v1")
            },
            sleepDurationMinutes: sleepDuration.map {
                TodayHealthMetricValue(value: $0, metricDay: day, sourceId: "my-whoop-noop",
                                        observedAt: generatedAt, rawFrontierTs: sleepFrontier,
                                        algorithmVersion: "daily-sleep-duration-v1")
            }
        )
    }

    func testUnknownLiveRefreshPreservesPersistedMetricValues() {
        let persisted = snapshot(generatedAt: 100, recovery: 78, strain: 64, sleepScore: 86,
                                 sleepDuration: 445, recoveryFrontier: 90, strainFrontier: 90,
                                 sleepFrontier: 90)
        let live = snapshot(generatedAt: 200)

        let resolved = TodayHealthSnapshotResolver.resolve(persisted: persisted, live: live)

        XCTAssertEqual(resolved?.recovery?.value, 78)
        XCTAssertEqual(resolved?.strain?.value, 64)
        XCTAssertEqual(resolved?.sleepScore?.value, 86)
        XCTAssertEqual(resolved?.sleepDurationMinutes?.value, 445)
    }

    func testAuthoritativeMissingClearsPersistedSameDayRecovery() {
        let persisted = snapshot(generatedAt: 100, recovery: 78, sleepDuration: 445)
        let live = snapshot(generatedAt: 200, authoritativeMetrics: [.recovery])

        let resolved = TodayHealthSnapshotResolver.resolve(persisted: persisted, live: live)

        XCTAssertNil(resolved?.recovery)
        XCTAssertNil(resolved?.dailyMetric.recovery)
        XCTAssertEqual(resolved?.sleepDurationMinutes?.value, 445)
    }

    func testNewDayStrainKeepsLatestRecoveryAndSleep() {
        let persisted = snapshot(day: "2026-08-03", generatedAt: 100, recovery: 74, strain: 60,
                                 sleepScore: 80, sleepDuration: 430)
        let live = snapshot(day: "2026-08-04", generatedAt: 200, strain: 7,
                            authoritativeMetrics: [.recovery, .strain, .sleepScore, .sleepDurationMinutes])

        let resolved = TodayHealthSnapshotResolver.resolve(persisted: persisted, live: live)

        XCTAssertEqual(resolved?.displayDay, "2026-08-04")
        XCTAssertEqual(resolved?.recovery?.value, 74)
        XCTAssertEqual(resolved?.recovery?.metricDay, "2026-08-03")
        XCTAssertEqual(resolved?.strain?.value, 7)
        XCTAssertEqual(resolved?.strain?.metricDay, "2026-08-04")
        XCTAssertEqual(resolved?.sleepScore?.value, 80)
        XCTAssertEqual(resolved?.sleepDurationMinutes?.value, 430)
    }

    func testVerifiedLiveV2StrainBeatsSnapshotWithLargerFrontier() {
        let persisted = snapshot(generatedAt: 100, strain: 0, strainFrontier: 1_000)
        let live = snapshot(generatedAt: 200, strain: 64, strainFrontier: 10,
                            authoritativeMetrics: [.strain])

        let resolved = TodayHealthSnapshotResolver.resolve(persisted: persisted, live: live)

        XCTAssertEqual(resolved?.strain?.value, 64)
        XCTAssertEqual(resolved?.dailyMetric.strain, 64)
    }

    func testDifferentContextNeverBlends() {
        let persisted = snapshot(generatedAt: 100, recovery: 78)
        let other = TodayHealthSnapshotContext(
            databaseInstanceId: "restored-db",
            dashboardProfileId: "dashboard:my-whoop",
            sourceLineage: "my-whoop,my-whoop-noop",
            algorithmBundleVersion: "today-health-v3|strain-v2|sleep-performance-v2"
        )
        let live = snapshot(generatedAt: 200, strain: 64, context: other)

        XCTAssertEqual(TodayHealthSnapshotResolver.resolve(persisted: persisted, live: live), live)
    }
}
