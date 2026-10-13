import XCTest
@testable import WhoopStore

final class WorkoutStrainDisplayTests: XCTestCase {
    /// WHOOP reports workout strain on 0...21; the importer stores it ×100/21 on NOOP's 0...100 axis.
    private let whoopDayStrainToStored = 100.0 / 21.0

    private func workout(source: String, strain: Double?, version: Int?,
                         startTs: Int = 1_000, sport: String = "Running") -> WorkoutRow {
        WorkoutRow(startTs: startTs, endTs: startTs + 3_600, sport: sport, source: source,
                   durationS: 3_600, energyKcal: 540, avgHr: 150, maxHr: 178,
                   strain: strain, distanceM: nil, zonesJSON: nil, notes: nil,
                   strainVersion: version)
    }

    /// One row per way a workout reaches the store, with what each resolver must say about it.
    private struct Fixture {
        let name: String
        let row: WorkoutRow
        /// `canonicalWorkout(row)?.storedValue`, pinned from before the display helper existed.
        let canonical: Double?
        let display: WorkoutStrainDisplay?
    }

    private var fixtures: [Fixture] {
        let whoopStored = 14.1 * whoopDayStrainToStored
        return [
            Fixture(name: "NOOP-detected V2",
                    row: workout(source: "my-whoop-noop", strain: 58, version: 2),
                    canonical: 58, display: .init(storedValue: 58, provenance: .noop)),
            Fixture(name: "live manual session V2",
                    row: workout(source: "manual", strain: 41.5, version: 2),
                    canonical: 41.5, display: .init(storedValue: 41.5, provenance: .noop)),
            Fixture(name: "WHOOP-sourced row NOOP scored itself",
                    row: workout(source: "whoop", strain: 62, version: 2),
                    canonical: 62, display: .init(storedValue: 62, provenance: .noop)),
            Fixture(name: "WHOOP import with strain",
                    row: workout(source: "whoop", strain: whoopStored, version: nil),
                    canonical: nil, display: .init(storedValue: whoopStored, provenance: .whoop)),
            Fixture(name: "WHOOP import with zero strain",
                    row: workout(source: "whoop", strain: 0, version: nil),
                    canonical: nil, display: .init(storedValue: 0, provenance: .whoop)),
            Fixture(name: "WHOOP import without strain",
                    row: workout(source: "whoop", strain: nil, version: nil),
                    canonical: nil, display: nil),
            Fixture(name: "manual row without a version",
                    row: workout(source: "manual", strain: 30, version: nil),
                    canonical: nil, display: nil),
            Fixture(name: "legacy NOOP-detected row without a version",
                    row: workout(source: "my-whoop-noop", strain: 44, version: nil),
                    canonical: nil, display: nil),
            Fixture(name: "Apple Health row",
                    row: workout(source: "apple-health", strain: 35, version: nil),
                    canonical: nil, display: nil),
            Fixture(name: "legacy Apple Health spelling",
                    row: workout(source: "apple_health", strain: 35, version: nil),
                    canonical: nil, display: nil),
            Fixture(name: "imported lifting session",
                    row: workout(source: "lifting", strain: 20, version: nil),
                    canonical: nil, display: nil),
            Fixture(name: "imported activity file",
                    row: workout(source: "activity-file", strain: 20, version: nil),
                    canonical: nil, display: nil),
            Fixture(name: "V2 row without a strain",
                    row: workout(source: "manual", strain: nil, version: 2),
                    canonical: nil, display: nil),
            Fixture(name: "unknown strain version",
                    row: workout(source: "whoop", strain: 50, version: 1),
                    canonical: nil, display: nil),
        ]
    }

    // MARK: - the display helper

    func testComputedV2RowsShowAsNoop() throws {
        let detected = try XCTUnwrap(StrainResolver.workoutStrainForDisplay(
            workout(source: "my-whoop-noop", strain: 58, version: 2)))
        XCTAssertEqual(detected, WorkoutStrainDisplay(storedValue: 58, provenance: .noop))
        let manual = try XCTUnwrap(StrainResolver.workoutStrainForDisplay(
            workout(source: "manual", strain: 41.5, version: 2)))
        XCTAssertEqual(manual.provenance, .noop)
    }

    func testNoopValueWinsOnAWhoopSourcedRowThatNoopScoredItself() throws {
        // WorkoutDetectedBackfill gives an imported row without a strain NOOP's own V2 score.
        let shown = try XCTUnwrap(StrainResolver.workoutStrainForDisplay(
            workout(source: "whoop", strain: 62, version: 2)))
        XCTAssertEqual(shown, WorkoutStrainDisplay(storedValue: 62, provenance: .noop))
    }

    func testImportedWhoopStrainShowsAsWhoopOnTheStoredAxis() throws {
        let stored = 14.1 * whoopDayStrainToStored          // what the importer writes for WHOOP's 14.1
        let shown = try XCTUnwrap(StrainResolver.workoutStrainForDisplay(
            workout(source: "whoop", strain: stored, version: nil)))
        XCTAssertEqual(shown.provenance, .whoop)
        XCTAssertEqual(shown.storedValue, stored)           // passed through, still on 0...100
        // The UI boundary's ×21/100 hands back exactly the number WHOOP showed.
        XCTAssertEqual(shown.storedValue * 21 / 100, 14.1, accuracy: 1e-12)
    }

    func testWhoopImportWithoutStrainShowsNothing() {
        XCTAssertNil(StrainResolver.workoutStrainForDisplay(
            workout(source: "whoop", strain: nil, version: nil)))
    }

    func testManualRowWithoutAVersionShowsNothing() {
        XCTAssertNil(StrainResolver.workoutStrainForDisplay(
            workout(source: "manual", strain: 30, version: nil)))
    }

    func testOnlyTheWhoopImportSourceIsLabelledWhoop() {
        for source in ["my-whoop-noop", "my-whoop", "whoop-noop", "apple-health", "apple_health",
                       "manual", "lifting", "activity-file", "", "strap"] {
            XCTAssertNil(StrainResolver.workoutStrainForDisplay(
                workout(source: source, strain: 40, version: nil)), "source \"\(source)\"")
        }
        XCTAssertEqual(StrainResolver.workoutStrainForDisplay(
            workout(source: "WHOOP", strain: 40, version: nil))?.provenance, .whoop)
    }

    func testAnImportedValueThatCannotBeDisplayedHonestlyShowsNothing() {
        for strain in [Double.nan, .infinity, -.infinity] {
            XCTAssertNil(StrainResolver.workoutStrainForDisplay(
                workout(source: "whoop", strain: strain, version: nil)), "strain \(strain)")
        }
    }

    // MARK: - canonical resolution is untouched

    func testCanonicalWorkoutStillIgnoresImportedAndUnversionedValues() throws {
        for fixture in fixtures {
            let canonical = StrainResolver.canonicalWorkout(fixture.row)
            XCTAssertEqual(canonical?.storedValue, fixture.canonical, fixture.name)
            guard let canonical else { continue }
            XCTAssertEqual(canonical, ResolvedStrain(
                day: nil, storedValue: try XCTUnwrap(fixture.row.strain), version: 2,
                origin: .computedWorkoutV2, sourceId: fixture.row.source,
                asOf: Date(timeIntervalSince1970: TimeInterval(fixture.row.endTs)),
                rawFrontierTs: fixture.row.endTs), fixture.name)
        }
    }

    func testDisplayHelperMatchesEveryFixtureAndNeverContradictsCanonical() {
        for fixture in fixtures {
            let shown = StrainResolver.workoutStrainForDisplay(fixture.row)
            XCTAssertEqual(shown, fixture.display, fixture.name)
            if let canonical = StrainResolver.canonicalWorkout(fixture.row) {
                XCTAssertEqual(shown?.storedValue, canonical.storedValue, fixture.name)
                XCTAssertEqual(shown?.provenance, .noop, fixture.name)
            }
            if shown?.provenance == .whoop {
                XCTAssertNil(StrainResolver.canonicalWorkout(fixture.row), fixture.name)
            }
        }
    }

    // MARK: - through the store

    func testRowsReadBackFromTheStoreResolveAsWrittenByEachImporter() async throws {
        let store = try await WhoopStore.inMemory()
        let imported = workout(source: "whoop", strain: 14.1 * whoopDayStrainToStored, version: nil,
                               startTs: 10_000, sport: "Running")
        let computed = workout(source: "my-whoop-noop", strain: 58, version: 2,
                               startTs: 20_000, sport: "detected")
        let manual = workout(source: "manual", strain: 30, version: nil,
                             startTs: 30_000, sport: "Yoga")
        try await store.upsertWorkouts([imported, computed, manual], deviceId: "my-whoop")

        let rows = try await store.workouts(deviceId: "my-whoop", from: 0, to: 100_000, limit: 10)
        XCTAssertEqual(rows.count, 3)
        let byStart = Dictionary(uniqueKeysWithValues: rows.map { ($0.startTs, $0) })
        let importedBack = try XCTUnwrap(byStart[10_000])
        XCTAssertNil(StrainResolver.canonicalWorkout(importedBack))
        XCTAssertEqual(StrainResolver.workoutStrainForDisplay(importedBack)?.provenance, .whoop)
        XCTAssertEqual(StrainResolver.workoutStrainForDisplay(importedBack)?.storedValue,
                       imported.strain)
        let computedBack = try XCTUnwrap(byStart[20_000])
        XCTAssertEqual(StrainResolver.workoutStrainForDisplay(computedBack),
                       WorkoutStrainDisplay(storedValue: 58, provenance: .noop))
        XCTAssertNil(StrainResolver.workoutStrainForDisplay(try XCTUnwrap(byStart[30_000])))
    }
}
