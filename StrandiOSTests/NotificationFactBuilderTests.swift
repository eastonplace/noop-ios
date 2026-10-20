import XCTest
import StrandAnalytics
import WhoopStore
@testable import NOOP

final class NotificationFactBuilderTests: XCTestCase {
    func testStrainConversionUsesCanonicalAxisAndRejectsMissingNonFinite() {
        XCTAssertNil(NotificationFactBuilder.displayStrain(nil))
        XCTAssertNil(NotificationFactBuilder.displayStrain(.nan))
        XCTAssertNil(NotificationFactBuilder.displayStrain(101))
        XCTAssertEqual(NotificationFactBuilder.displayStrain(0), 0)
        XCTAssertEqual(NotificationFactBuilder.displayStrain(100), StrainScorerV2.displayValue(fromStored: 100))
        XCTAssertFalse(NotificationFactBuilder.recoveryRepairIntegrated)
    }
    func testOnlyCurrentSettledCanonicalLiveWorkoutProducesFact() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func row(source: String = "manual", version: Int? = 2, end: Int = 1_799_999_900) -> WorkoutRow {
            WorkoutRow(startTs: 1_799_996_000, endTs: end, sport: "Running", source: source,
                durationS: 3900, energyKcal: nil, avgHr: 140, maxHr: 170, strain: 50,
                distanceM: nil, zonesJSON: nil, notes: nil, strainVersion: version)
        }
        XCTAssertNotNil(NotificationFactBuilder.workout(row(), source: "device", revision: "2", now: now, isLiveCompletion: true))
        XCTAssertNil(NotificationFactBuilder.workout(row(), source: "device", revision: "2", now: now, isLiveCompletion: false))
        XCTAssertNil(NotificationFactBuilder.workout(row(source: "whoop-import"), source: "device", revision: "2", now: now, isLiveCompletion: true))
        XCTAssertNil(NotificationFactBuilder.workout(row(version: nil), source: "device", revision: "2", now: now, isLiveCompletion: true))
        XCTAssertNil(NotificationFactBuilder.workout(row(end: 1_799_996_100), source: "device", revision: "2", now: now, isLiveCompletion: true))
    }
}
