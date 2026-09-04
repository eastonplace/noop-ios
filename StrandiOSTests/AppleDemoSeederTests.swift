import Foundation
import StrandAnalytics
import WhoopStore
import XCTest
@testable import NOOP

final class AppleDemoSeederTests: XCTestCase {
    func testDemoPreSleepOverrideDoesNotPersistIntoNormalRelaunch() throws {
        let suiteName = "AppleDemoSeederTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        AppleDemoSeeder.seedDemoPreferences(defaults: defaults)

        XCTAssertNil(defaults.object(forKey: PreSleepHeartRateFeedback.enabledKey))
        XCTAssertTrue(AppleDemoSeeder.effectivePreSleepFeedbackEnabled(
            userOptIn: defaults.bool(forKey: PreSleepHeartRateFeedback.enabledKey),
            demoRequested: true
        ))
        XCTAssertFalse(AppleDemoSeeder.effectivePreSleepFeedbackEnabled(
            userOptIn: defaults.bool(forKey: PreSleepHeartRateFeedback.enabledKey),
            demoRequested: false
        ))
    }

    func testNormalRelaunchPreservesAnExplicitUserOptIn() {
        XCTAssertTrue(AppleDemoSeeder.effectivePreSleepFeedbackEnabled(
            userOptIn: true,
            demoRequested: false
        ))
    }

    func testDemoGateRequiresSimulatorAndExplicitSeedArgument() {
        XCTAssertTrue(AppleDemoSeeder.isSeedRequested(
            arguments: ["NOOP", "--demo-seed"],
            isSimulator: true
        ))
        XCTAssertFalse(AppleDemoSeeder.isSeedRequested(
            arguments: ["NOOP", "--demo-seed"],
            isSimulator: false
        ))
        XCTAssertFalse(AppleDemoSeeder.isSeedRequested(
            arguments: ["NOOP"],
            isSimulator: true
        ))
    }

    func testDevicesQARouteCannotRunWithoutSimulatorSeedGate() {
        let arguments = ["NOOP", "--demo-seed", "--demo-devices-qa"]
        XCTAssertTrue(AppleDemoSeeder.isDevicesQARequested(
            arguments: arguments,
            isSimulator: true
        ))
        XCTAssertFalse(AppleDemoSeeder.isDevicesQARequested(
            arguments: arguments,
            isSimulator: false
        ))
        XCTAssertFalse(AppleDemoSeeder.isDevicesQARequested(
            arguments: ["NOOP", "--demo-devices-qa"],
            isSimulator: true
        ))
    }

    func testPhysiologicalHistoryHasCompleteMinuteCadenceAndLowerSleepHR() throws {
        let day = 24 * 60 * 60
        let sleeps = (0..<3).map { index in
            CachedSleepSession(
                startTs: 100_000 + index * day,
                endTs: 100_000 + index * day + 8 * 60 * 60,
                efficiency: 91,
                restingHr: 53,
                avgHrv: 68,
                stagesJSON: nil
            )
        }

        let samples = AppleDemoSeeder.physiologicalHeartRateFixture(sleeps: sleeps)
        XCTAssertFalse(samples.isEmpty)
        XCTAssertTrue(zip(samples, samples.dropFirst()).allSatisfy { pair in
            pair.1.ts - pair.0.ts == 60
        })
        XCTAssertEqual(Set(samples.map(\.ts)).count, samples.count)

        let latest = try XCTUnwrap(sleeps.last)
        let sleepValues = samples.filter {
            $0.ts >= latest.effectiveStartTs && $0.ts < latest.endTs
        }.map(\.bpm)
        let wakeValues = samples.filter {
            $0.ts >= sleeps[1].endTs && $0.ts < latest.effectiveStartTs - 30 * 60
        }.map(\.bpm)
        XCTAssertGreaterThanOrEqual(sleepValues.count, 8 * 60 - 1)
        XCTAssertGreaterThan(wakeValues.count, 30)
        XCTAssertLessThan(mean(sleepValues), mean(wakeValues))
    }

    func testPreSleepSeriesUsesEveryProductionKeyAndEnoughBaselineNights() {
        let days = (1...8).map { day in
            daily(String(format: "2026-08-%02d", day))
        }
        let sleeps = days.indices.map { index in
            CachedSleepSession(
                startTs: 10_000 + index * 86_400,
                endTs: 10_000 + index * 86_400 + 8 * 3_600,
                efficiency: 0.9,
                restingHr: 52,
                avgHrv: 60,
                stagesJSON: nil
            )
        }

        let points = AppleDemoSeeder.preSleepMetricFixture(days: days, sleeps: sleeps)
        XCTAssertEqual(points.count, days.count * PreSleepHeartRateFeedback.metricKeys.count)
        XCTAssertEqual(Set(points.map(\.key)), Set(PreSleepHeartRateFeedback.metricKeys))
        XCTAssertEqual(Set(points.map(\.day)).count, days.count)

        let means = points.filter { $0.key == PreSleepHeartRateFeedback.meanMetricKey }
        XCTAssertGreaterThan(try XCTUnwrap(means.last?.value), try XCTUnwrap(means.dropLast().map(\.value).max()))
    }

    func testComparisonFixtureKeepsSourceSpecificSignalsSeparate() throws {
        let source = DailyMetric(
            day: "2026-09-03",
            totalSleepMin: 440,
            efficiency: 91,
            deepMin: 90,
            remMin: 100,
            lightMin: 250,
            disturbances: 5,
            restingHr: 54,
            avgHrv: 68,
            recovery: 82,
            strain: 46,
            exerciseCount: 1,
            spo2Pct: 97.2,
            skinTempDevC: -0.1,
            steps: 10_200,
            activeKcalEst: 620
        )

        let peer = try XCTUnwrap(AppleDemoSeeder.comparisonDailyFixture(days: [source]).first)
        XCTAssertEqual(peer.day, source.day)
        XCTAssertNotEqual(peer.restingHr, source.restingHr)
        XCTAssertNotEqual(peer.avgHrv, source.avgHrv)
        XCTAssertNil(peer.recovery)
        XCTAssertNil(peer.strain)
        XCTAssertNil(peer.steps)
        XCTAssertNil(peer.activeKcalEst)
    }

    private func daily(_ day: String) -> DailyMetric {
        DailyMetric(
            day: day,
            totalSleepMin: 430,
            efficiency: 90,
            deepMin: 86,
            remMin: 99,
            lightMin: 245,
            disturbances: 5,
            restingHr: 54,
            avgHrv: 67,
            recovery: 80,
            strain: 42,
            exerciseCount: 1
        )
    }

    private func mean(_ values: [Int]) -> Double {
        guard !values.isEmpty else { return 0 }
        return Double(values.reduce(0, +)) / Double(values.count)
    }
}
