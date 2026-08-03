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
        context: TodayHealthSnapshotContext? = nil,
        metricStates: [TodayHealthSnapshot.Metric: TodayHealthMetricState]? = nil,
        generation: Int64 = 0,
        schemaVersion: Int = TodayHealthSnapshot.currentSchemaVersion
    ) -> TodayHealthSnapshot {
        let snapshotContext = context ?? self.context
        return TodayHealthSnapshot(
            scopeId: "dashboard:my-whoop|\(snapshotContext.identifier)", context: snapshotContext,
            deviceId: "my-whoop", displayDay: day, logicalDay: day, localDay: day,
            generatedAt: generatedAt,
            rawFrontierTs: [recoveryFrontier, strainFrontier, sleepFrontier].compactMap { $0 }.max(),
            generation: generation, schemaVersion: schemaVersion,
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
            },
            metricStates: metricStates
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
        XCTAssertNil(resolved?.dailyMetric.recovery)
        XCTAssertNil(resolved?.dailyMetric.totalSleepMin)
    }

    func testSameDayAuthoritativeUnavailableClearsPersistedValueEvenWithGenerationZero() {
        let persisted = snapshot(generatedAt: 100, recovery: 78, recoveryFrontier: 90)
        let live = snapshot(
            generatedAt: 200,
            recoveryFrontier: 90,
            authoritativeMetrics: [.recovery],
            metricStates: [
                .recovery: .unavailable(TodayHealthUnavailableEvidence(
                    metricDay: "2026-08-03", sourceId: "my-whoop-noop", reason: .absent,
                    observedAt: 200, rawFrontierTs: 90, algorithmVersion: "daily-recovery-v1",
                    generation: 0
                ))
            ]
        )

        let resolved = TodayHealthSnapshotResolver.resolve(persisted: persisted, live: live)

        XCTAssertNil(resolved?.recovery)
        XCTAssertNil(resolved?.dailyMetric.recovery)
        guard case let .unavailable(evidence) = resolved?.recoveryState else {
            return XCTFail("Expected an unavailable recovery state")
        }
        XCTAssertEqual(evidence.reason, .absent)
        XCTAssertEqual(evidence.generation, 0)
    }

    func testNewDayRecoveryUnavailableCarriesPriorNightUnlessExplicitlyDeleted() {
        let persisted = snapshot(day: "2026-08-03", generatedAt: 100, recovery: 74,
                                 sleepScore: 80, sleepDuration: 430)
        let absent = snapshot(
            day: "2026-08-04", generatedAt: 200, authoritativeMetrics: [.recovery],
            metricStates: [
                .recovery: .unavailable(TodayHealthUnavailableEvidence(
                    metricDay: "2026-08-04", sourceId: "my-whoop-noop", reason: .absent,
                    observedAt: 200, rawFrontierTs: 100, algorithmVersion: "daily-recovery-v1",
                    generation: 0
                ))
            ]
        )
        let deleted = snapshot(
            day: "2026-08-04", generatedAt: 201, authoritativeMetrics: [.recovery],
            metricStates: [
                .recovery: .unavailable(TodayHealthUnavailableEvidence(
                    metricDay: "2026-08-04", sourceId: "my-whoop-noop", reason: .deleted,
                    observedAt: 201, rawFrontierTs: 101, algorithmVersion: "daily-recovery-v1",
                    generation: 0
                ))
            ]
        )

        let carried = TodayHealthSnapshotResolver.resolve(persisted: persisted, live: absent)
        let cleared = TodayHealthSnapshotResolver.resolve(persisted: persisted, live: deleted)
        let noPrior = TodayHealthSnapshotResolver.resolve(
            persisted: snapshot(day: "2026-08-03", generatedAt: 99), live: absent
        )

        XCTAssertEqual(carried?.recovery?.value, 74)
        XCTAssertEqual(carried?.recovery?.metricDay, "2026-08-03")
        XCTAssertEqual(carried?.sleepScore?.metricDay, "2026-08-03")
        XCTAssertEqual(carried?.sleepDurationMinutes?.metricDay, "2026-08-03")
        XCTAssertNil(carried?.dailyMetric.recovery)
        XCTAssertNil(carried?.dailyMetric.totalSleepMin)
        XCTAssertNil(cleared?.recovery)
        guard case let .unavailable(evidence) = cleared?.recoveryState else {
            return XCTFail("Expected an unavailable recovery state")
        }
        XCTAssertEqual(evidence.reason, .deleted)
        guard case let .unavailable(noPriorEvidence) = noPrior?.recoveryState else {
            return XCTFail("Expected new-day unavailable recovery state without a prior value")
        }
        XCTAssertEqual(noPriorEvidence.metricDay, "2026-08-04")
    }

    func testNewDayStrainUnavailableNeverCarriesPriorDayValue() {
        let persisted = snapshot(day: "2026-08-03", generatedAt: 100, strain: 64)
        let live = snapshot(
            day: "2026-08-04", generatedAt: 200, authoritativeMetrics: [.strain],
            metricStates: [
                .strain: .unavailable(TodayHealthUnavailableEvidence(
                    metricDay: "2026-08-04", sourceId: "my-whoop-noop", reason: .absent,
                    observedAt: 200, rawFrontierTs: 100, algorithmVersion: "strain-v2-daily",
                    generation: 0
                ))
            ]
        )

        let resolved = TodayHealthSnapshotResolver.resolve(persisted: persisted, live: live)

        XCTAssertNil(resolved?.strain)
        XCTAssertNil(resolved?.dailyMetric.strain)
        guard case let .unavailable(evidence) = resolved?.strainState else {
            return XCTFail("Expected an unavailable strain state")
        }
        XCTAssertEqual(evidence.metricDay, "2026-08-04")
    }

    func testUnavailableGenerationBeatsOlderValue() {
        let persisted = snapshot(
            generatedAt: 100, recoveryFrontier: 100, authoritativeMetrics: [.recovery],
            metricStates: [
                .recovery: .unavailable(TodayHealthUnavailableEvidence(
                    metricDay: "2026-08-03", sourceId: "my-whoop-noop", reason: .absent,
                    observedAt: 100, rawFrontierTs: 100, algorithmVersion: "daily-recovery-v1",
                    generation: 5
                ))
            ], generation: 5
        )
        let staleLive = snapshot(
            generatedAt: 200, recovery: 42, recoveryFrontier: 99, authoritativeMetrics: [.recovery],
            metricStates: [
                .recovery: .value(TodayHealthMetricValue(
                    value: 42, metricDay: "2026-08-03", sourceId: "my-whoop-noop", observedAt: 200,
                    rawFrontierTs: 99, algorithmVersion: "daily-recovery-v1", generation: 0
                ))
            ]
        )

        let resolved = TodayHealthSnapshotResolver.resolve(persisted: persisted, live: staleLive)

        guard case let .unavailable(evidence) = resolved?.recoveryState else {
            return XCTFail("Expected persisted unavailable recovery state")
        }
        XCTAssertEqual(evidence.generation, 5)
        XCTAssertNil(resolved?.recovery)

        let freshLive = snapshot(
            generatedAt: 201, recovery: 43, recoveryFrontier: 100, authoritativeMetrics: [.recovery],
            metricStates: [
                .recovery: .value(TodayHealthMetricValue(
                    value: 43, metricDay: "2026-08-03", sourceId: "my-whoop-noop", observedAt: 201,
                    rawFrontierTs: 100, algorithmVersion: "daily-recovery-v1", generation: 6
                ))
            ], generation: 6
        )

        let corrected = TodayHealthSnapshotResolver.resolve(persisted: persisted, live: freshLive)

        XCTAssertEqual(corrected?.recovery?.value, 43)
        XCTAssertEqual(corrected?.recovery?.generation, 6)
    }

    func testSchemaThreeSnapshotDecodesToExplicitSchemaFourStates() throws {
        let legacy = snapshot(
            generatedAt: 100, recovery: 78,
            authoritativeMetrics: [.recovery, .strain],
            schemaVersion: 3
        )

        let data = try JSONEncoder().encode(legacy)
        let migrated = try JSONDecoder().decode(TodayHealthSnapshot.self, from: data)

        XCTAssertEqual(migrated.schemaVersion, TodayHealthSnapshot.currentSchemaVersion)
        guard case let .value(recovery) = migrated.recoveryState else {
            return XCTFail("Expected migrated recovery value")
        }
        XCTAssertEqual(recovery.value, 78)
        guard case let .unavailable(evidence) = migrated.strainState else {
            return XCTFail("Expected migrated authoritative strain absence")
        }
        XCTAssertEqual(evidence.reason, .absent)
        guard case .unknown = migrated.sleepScoreState else {
            return XCTFail("Expected non-authoritative sleep score to remain unknown")
        }
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
