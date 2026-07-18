import XCTest
@testable import WhoopStore

final class StrainResolutionTests: XCTestCase {
    private func day(_ key: String = "2026-07-18", strain: Double? = nil,
                     version: Int? = nil, sleep: Double? = nil, steps: Int? = nil) -> DailyMetric {
        DailyMetric(day: key, totalSleepMin: sleep, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil,
                    recovery: nil, strain: strain, exerciseCount: nil, steps: steps,
                    strainVersion: version)
    }

    func testDailyReplacingPreservesUnspecifiedProvenance() {
        let original = day(strain: 61, version: 2, sleep: 420)
        let changed = original.replacing(steps: .some(12_345))
        XCTAssertEqual(changed.strain, 61)
        XCTAssertEqual(changed.strainVersion, 2)
        XCTAssertEqual(changed.totalSleepMin, 420)
        XCTAssertEqual(changed.steps, 12_345)
    }

    func testWorkoutReplacingPreservesVersionTwo() {
        let original = WorkoutRow(startTs: 100, endTs: 800, sport: "run", source: "manual",
                                  durationS: 700, energyKcal: 80, avgHr: 150, maxHr: 180,
                                  strain: 55, distanceM: 2_000, zonesJSON: "{}", notes: "old",
                                  strainVersion: 2)
        let changed = original.replacing(sport: "trail-run", notes: .some("edited"))
        XCTAssertEqual(changed.strain, 55)
        XCTAssertEqual(changed.strainVersion, 2)
        XCTAssertEqual(changed.sport, "trail-run")
        XCTAssertEqual(changed.notes, "edited")
    }

    func testComputedV2WinsCanonicalAndImportedRemainsComparison() {
        let computed = DailyStrainCandidate(metric: day(strain: 58, version: 2),
                                            sourceId: "strap-noop", rawFrontierTs: 200)
        let imported = DailyStrainCandidate(metric: day(strain: 72),
                                            sourceId: "whoop-import", rawFrontierTs: nil)
        XCTAssertEqual(StrainResolver.canonicalDay(day: "2026-07-18", computedRows: [computed],
                                                   importedRows: [imported], live: nil)?.storedValue, 58)
        XCTAssertEqual(StrainResolver.importedComparison(day: "2026-07-18",
                                                         importedRows: [imported])?.storedValue, 72)
    }

    func testLegacyOnlyDoesNotResolveCanonicalV2() {
        let legacy = DailyStrainCandidate(metric: day(strain: 44), sourceId: "strap-noop")
        XCTAssertNil(StrainResolver.canonicalDay(day: "2026-07-18", computedRows: [legacy],
                                                 importedRows: [], live: nil))
    }

    func testStaleLiveLosesAndFreshLiveWins() {
        let persisted = DailyStrainCandidate(metric: day(strain: 60, version: 2),
                                             sourceId: "strap-noop", rawFrontierTs: 200)
        let stale = ResolvedStrain(day: "2026-07-18", storedValue: 62, version: 2,
                                   origin: .liveDayV2, sourceId: "live", rawFrontierTs: 199)
        let fresh = ResolvedStrain(day: "2026-07-18", storedValue: 64, version: 2,
                                   origin: .liveDayV2, sourceId: "live", rawFrontierTs: 201)
        XCTAssertEqual(StrainResolver.canonicalDay(day: "2026-07-18", computedRows: [persisted],
                                                   importedRows: [], live: stale)?.storedValue, 60)
        XCTAssertEqual(StrainResolver.canonicalDay(day: "2026-07-18", computedRows: [persisted],
                                                   importedRows: [], live: fresh)?.storedValue, 64)
    }
}
