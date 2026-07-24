import XCTest
import WhoopStore
@testable import StrandAnalytics

final class WorkoutDetectedBackfillTests: XCTestCase {
    private func row(
        energy: Double? = nil,
        average: Int? = nil,
        peak: Int? = nil,
        strain: Double? = nil,
        strainVersion: Int? = nil
    ) -> WorkoutRow {
        WorkoutRow(
            startTs: 100,
            endTs: 700,
            sport: "Run",
            source: "manual",
            durationS: 600,
            energyKcal: energy,
            avgHr: average,
            maxHr: peak,
            strain: strain,
            distanceM: 2_500,
            zonesJSON: "{\"zone1\":10}",
            notes: "Keep me",
            strainVersion: strainVersion
        )
    }

    private let computed = WorkoutDetectedBackfill.ComputedValues(
        averageHeartRate: 152,
        peakHeartRate: 181,
        caloriesKcal: 245,
        strain: 38,
        strainVersion: 2
    )

    func testFillsOnlyMissingComputedFields() {
        let original = row()
        let result = WorkoutDetectedBackfill.applying(computed, to: original)

        XCTAssertEqual(result.avgHr, 152)
        XCTAssertEqual(result.maxHr, 181)
        XCTAssertEqual(result.energyKcal, 245)
        XCTAssertEqual(result.strain, 38)
        XCTAssertEqual(result.strainVersion, 2)
        XCTAssertEqual(result.startTs, original.startTs)
        XCTAssertEqual(result.endTs, original.endTs)
        XCTAssertEqual(result.sport, original.sport)
        XCTAssertEqual(result.source, original.source)
        XCTAssertEqual(result.durationS, original.durationS)
        XCTAssertEqual(result.distanceM, original.distanceM)
        XCTAssertEqual(result.zonesJSON, original.zonesJSON)
        XCTAssertEqual(result.notes, original.notes)
    }

    func testNeverOverwritesUserOrImportedValues() {
        let original = row(
            energy: 111,
            average: 130,
            peak: 165,
            strain: 22,
            strainVersion: 7
        )
        XCTAssertEqual(WorkoutDetectedBackfill.applying(computed, to: original), original)
    }

    func testExistingStrainKeepsItsVersionWhileOtherFieldsFill() {
        let original = row(strain: 22, strainVersion: 7)
        let result = WorkoutDetectedBackfill.applying(computed, to: original)

        XCTAssertEqual(result.avgHr, 152)
        XCTAssertEqual(result.maxHr, 181)
        XCTAssertEqual(result.energyKcal, 245)
        XCTAssertEqual(result.strain, 22)
        XCTAssertEqual(result.strainVersion, 7)
    }

    func testMissingComputedOptionalsStayMissing() {
        let unavailable = WorkoutDetectedBackfill.ComputedValues(
            averageHeartRate: nil,
            peakHeartRate: nil,
            caloriesKcal: nil,
            strain: nil,
            strainVersion: 99
        )
        let result = WorkoutDetectedBackfill.applying(unavailable, to: row())
        XCTAssertNil(result.avgHr)
        XCTAssertNil(result.maxHr)
        XCTAssertNil(result.energyKcal)
        XCTAssertNil(result.strain)
        XCTAssertNil(result.strainVersion)
    }

    func testInvalidComputedValuesFailClosedInsteadOfPollutingARealWorkout() {
        let invalid = WorkoutDetectedBackfill.ComputedValues(
            averageHeartRate: 0,
            peakHeartRate: 999,
            caloriesKcal: .infinity,
            strain: -.infinity,
            strainVersion: 2
        )
        XCTAssertEqual(WorkoutDetectedBackfill.applying(invalid, to: row()), row())
    }
}
